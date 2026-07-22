import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'module_repository.dart';
import 'native_bridge.dart';
import 'root_shell.dart';
import 'update_checker.dart';

/// Where the combined-update flow is: idle, downloading each artifact,
/// installing them, done (reboot pending), or errored out.
enum UpdatePhase { idle, downloading, installing, done, error }

/// One installable artifact in the combined-update flow (the app APK or the
/// kernel/modules build), with its live download progress and install state.
class UpdateTask {
  UpdateTask(this.label);

  final String label;
  double? downloadProgress; // 0..1, null while starting / indeterminate
  bool installed = false;

  bool get isKernel => label.startsWith('Kernel');
}

/// Owns everything update-related: the self-update APK, the kernel/OOT-modules
/// build, the combined download+install flow, A/B slot selection and the
/// pending-reboot marker. Split out of [AppController] so the update dialog and
/// the app-bar pill rebuild only on update changes, not on the 1s system scan.
class UpdateController extends ChangeNotifier {
  UpdateController(this._repo);

  final ModuleRepository _repo;
  final UpdateChecker _updates = UpdateChecker();
  bool _disposed = false;

  // ── Self-update (GitHub Releases, independent of the module zip) ────────
  UpdateInfo? availableUpdate;

  // ── Combined update (App APK + Kernel/OOT-modules) ──────────────────────
  KernelUpdateInfo? availableKernelUpdate;
  int installedModulesVersionCode = 0;

  // A/B slot selection for the kernel flash (default: the active slot).
  bool abDevice = false;
  String activeSlot = '';
  String selectedSlot = '';

  UpdatePhase updatePhase = UpdatePhase.idle;
  List<UpdateTask> updateTasks = [];
  bool combinedUpdateBusy = false;
  String? combinedUpdateError;
  bool rebootPending = false;

  /// False on hardware this build isn't for (not a Xiaomi 17-series / sm8850
  /// device). The updater is then hard-disabled: no probes, no pill, no
  /// install — an sm8850 kernel would brick a different device.
  bool deviceSupported = true;

  /// Runs every update probe once root is granted — but first gates on the
  /// device: on unsupported hardware nothing is probed or offered.
  Future<void> init() async {
    deviceSupported = isSupportedDevice(await _repo.deviceIdentity());
    if (_disposed) return;
    if (!deviceSupported) {
      notifyListeners();
      return;
    }
    await Future.wait([
      _checkForUpdate(),
      _checkForKernelUpdate(),
      _refreshInstalledModulesVersion(),
      _refreshSlotInfo(),
      _refreshRebootPending(),
    ]);
  }

  Future<void> _checkForUpdate() async {
    final update = await _updates.check();
    if (_disposed) return;
    if (update != null) {
      availableUpdate = update;
      notifyListeners();
    }
  }

  Future<void> _checkForKernelUpdate() async {
    final info = await _updates.checkKernel();
    if (_disposed) return;
    if (info != null) {
      availableKernelUpdate = info;
      notifyListeners();
    }
  }

  Future<void> _refreshInstalledModulesVersion() async {
    final v = await _repo.installedModulesVersionCode();
    if (_disposed) return;
    installedModulesVersionCode = v;
    notifyListeners();
  }

  /// The slots the user can flash to ("_a", "_b") — empty on a non-A/B device.
  List<String> get slots => abDevice ? const ['_a', '_b'] : const [];

  void setSelectedSlot(String slot) {
    if (slot == selectedSlot) return;
    selectedSlot = slot;
    notifyListeners();
  }

  Future<void> _refreshSlotInfo() async {
    final (ab, slot) = await _repo.slotInfo();
    if (_disposed) return;
    abDevice = ab;
    activeSlot = slot;
    if (selectedSlot.isEmpty) selectedSlot = slot;
    notifyListeners();
  }

  /// A strictly newer kernel/modules build than the installed one is offered.
  bool get kernelUpdateAvailable =>
      availableKernelUpdate != null &&
      availableKernelUpdate!.versionCode > installedModulesVersionCode;

  /// Anything to act on — the app APK, a kernel build, or a reboot still owed
  /// from an install done earlier this boot. Always false on unsupported
  /// hardware, so the update pill/dialog never appear there.
  bool get anyUpdateAvailable =>
      deviceSupported &&
      (rebootPending || availableUpdate != null || kernelUpdateAvailable);

  int get installedCount => updateTasks.where((t) => t.installed).length;

  /// Marker file (app-private) holding the boot_id at install time — its
  /// presence + a matching boot_id means the reboot is still owed.
  Future<File?> _rebootMarker() async {
    final dir = await NativeBridge.filesDir();
    return dir == null ? null : File('$dir/reboot_pending');
  }

  /// Re-derives [rebootPending] on launch: true only if an install this boot
  /// left the marker AND we haven't rebooted since (boot_id still matches).
  Future<void> _refreshRebootPending() async {
    final f = await _rebootMarker();
    if (f == null || _disposed || !await f.exists()) return;
    final stored = (await f.readAsString()).trim();
    final current = await _repo.currentBootId();
    if (_disposed) return;
    if (stored.isNotEmpty && stored == current) {
      rebootPending = true;
    } else {
      try {
        await f.delete();
      } catch (_) {}
      rebootPending = false;
    }
    notifyListeners();
  }

  Future<void> _persistRebootPending() async {
    final f = await _rebootMarker();
    if (f == null) return;
    try {
      await f.writeAsString(await _repo.currentBootId());
    } catch (_) {}
  }

  /// Downloads and installs everything available in one pass: the kernel
  /// OOT-modules zip (via KernelSU/Magisk; the kernel zip is dropped in
  /// /sdcard/Download for a manual flash), then the app APK. Modules go first
  /// (they can't kill us); the APK is last because `pm install` may restart the
  /// app. A reboot afterwards activates the modules. UI reads [updateTasks] /
  /// [updatePhase]; nothing is flashed to the boot image by the app.
  Future<void> installAllUpdates() async {
    if (combinedUpdateBusy || !deviceSupported) return;
    final app = availableUpdate;
    final kern = kernelUpdateAvailable ? availableKernelUpdate : null;
    if (app == null && kern == null) return;

    combinedUpdateBusy = true;
    combinedUpdateError = null;
    rebootPending = false;
    updateTasks = [
      if (kern != null) UpdateTask('Kernel & modules · ${kern.dateLabel}'),
      if (app != null) UpdateTask('App · v${app.version}'),
    ];
    updatePhase = UpdatePhase.downloading;
    notifyListeners();

    final tmp = Directory.systemTemp.path;
    File? modsFile, kernFile, apkFile;
    try {
      // ── Download phase ──
      if (kern != null) {
        final task = updateTasks.firstWhere((t) => t.isKernel);
        modsFile = await _updates.downloadZip(
            kern.modulesUrl, '$tmp/${kern.modulesName}', onProgress: (r, t) {
          task.downloadProgress = t > 0 ? r / t : null;
          notifyListeners();
        });
        if (kern.kernelUrl != null && kern.kernelName != null) {
          kernFile = await _updates.downloadZip(
              kern.kernelUrl!, '$tmp/${kern.kernelName}', onProgress: (r, t) {
            task.downloadProgress = t > 0 ? r / t : null;
            notifyListeners();
          });
        }
        task.downloadProgress = 1;
        notifyListeners();
      }
      // ── Install kernel/modules (they can't restart us). ──
      updatePhase = UpdatePhase.installing;
      notifyListeners();

      if (kern != null && modsFile != null) {
        final res = await _repo.installModuleZip(modsFile.path);
        if (res.stdout.contains('NO_MODULE_MANAGER')) {
          throw Exception('No KernelSU/Magisk CLI found to install the module.');
        }
        if (!res.ok) {
          throw Exception('Module install failed: ${res.errorSummary}');
        }
        // Flash the boot image (AnyKernel3) to the chosen slot, and keep a copy
        // in Download as a manual-flash fallback.
        if (kernFile != null && kern.kernelName != null) {
          final inactive = abDevice &&
              selectedSlot.isNotEmpty &&
              selectedSlot != activeSlot;
          final fres =
              await _repo.flashKernelZip(kernFile.path, inactiveSlot: inactive);
          if (!fres.stdout.contains('AK3_EXIT:0') ||
              fres.stdout.toLowerCase().contains('abort')) {
            throw Exception('Kernel flash failed: ${fres.errorSummary}');
          }
          await _repo.copyToDownloads(kernFile.path, kern.kernelName!);
        }
        updateTasks.firstWhere((t) => t.isKernel).installed = true;
        rebootPending = true;
        await _persistRebootPending();
        notifyListeners();
      }
      // ── App LAST: download, then install. `pm install -r -d` swaps the
      // running app out, so it must be the final step. An app-only update never
      // sets rebootPending, so it doesn't ask for a reboot.
      if (app != null) {
        updatePhase = UpdatePhase.downloading;
        notifyListeners();
        final task = updateTasks.firstWhere((t) => !t.isKernel);
        apkFile = await _updates.download(app.apkUrl, onProgress: (r, t) {
          task.downloadProgress = t > 0 ? r / t : null;
          notifyListeners();
        });
        task.downloadProgress = 1;
        updatePhase = UpdatePhase.installing;
        notifyListeners();
        final err = await _installApk(apkFile);
        if (err != null) throw Exception(err);
        task.installed = true;
        availableUpdate = null;
        notifyListeners();
      }

      updatePhase = UpdatePhase.done;
      notifyListeners();
    } catch (e) {
      combinedUpdateError = '$e';
      updatePhase = UpdatePhase.error;
      notifyListeners();
    } finally {
      for (final f in [modsFile, kernFile, apkFile]) {
        try {
          await f?.delete();
        } catch (_) {}
      }
      combinedUpdateBusy = false;
      notifyListeners();
    }
  }

  Future<void> rebootForUpdate() => _repo.reboot();

  /// Installs an already-downloaded APK via root; returns an error string or
  /// null. `pm install -r -d` swaps the running app out from under itself, so
  /// the combined flow does this LAST. installd can't read the app's private
  /// cache, so the APK is staged in /data/local/tmp first.
  Future<String?> _installApk(File apk) async {
    const dest = '/data/local/tmp/pmm_update.apk';
    final result = await RootShell.run(
      "cp '${apk.path}' '$dest' && chmod 644 '$dest' && "
      "pm install -r -d '$dest'; rm -f '$dest'",
      timeout: const Duration(seconds: 120),
    );
    if (!result.stdout.contains('Success')) return _installErrorMessage(result);
    return null;
  }

  /// Maps common INSTALL_FAILED_* codes to plain language.
  String _installErrorMessage(ShellResult r) {
    final lower = r.stdout.toLowerCase();
    if (lower.contains('signatures do not match') ||
        lower.contains('update_incompatible') ||
        lower.contains('inconsistent_certificates') ||
        lower.contains('no_matching_signatures')) {
      return 'Signature mismatch — the installed build was signed with a '
          'different key than this release. Uninstall the current app, then '
          'install the update manually.';
    }
    if (lower.contains('version_downgrade') || lower.contains('older_sdk')) {
      return 'This release is older than the version already installed.';
    }
    if (lower.contains('insufficient_storage')) {
      return 'Not enough free storage to install the update.';
    }
    if (lower.contains('invalid_apk') ||
        lower.contains('parse_failed') ||
        lower.contains('no_certificates')) {
      return 'The downloaded update is invalid or corrupt.';
    }
    final fail = RegExp(r'Failure \[[^\]]*\]').firstMatch(r.stdout);
    return 'Install failed: ${fail?.group(0) ?? r.errorSummary}';
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
