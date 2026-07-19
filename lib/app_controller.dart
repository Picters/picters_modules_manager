import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'module_dependencies.dart';
import 'module_info.dart';
import 'module_repository.dart';
import 'native_bridge.dart';
import 'root_shell.dart';
import 'update_checker.dart';
import 'usb_devices.dart';

enum RootStatus { checking, granted, denied }

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

/// Single source of truth for the UI. Owns the 1-second live poll, the root
/// status, and all the mutating actions. Everything is funnelled through the
/// persistent root shell, so a poll is one cheap round-trip.
class AppController extends ChangeNotifier {
  AppController(this._repo);

  final ModuleRepository _repo;
  final UpdateChecker _updates = UpdateChecker();

  RootStatus rootStatus = RootStatus.checking;
  SystemState state = SystemState.empty;

  bool wifiBusy = false;
  final Set<String> moduleBusy = {};

  Timer? _timer;
  bool _foreground = true;
  bool _polling = false;
  String _lastFingerprint = '';

  bool _disposed = false;

  Future<void> init() async {
    rootStatus = RootStatus.checking;
    notifyListeners();
    final ok = await RootShell.checkRoot();
    if (_disposed) return;
    rootStatus = ok ? RootStatus.granted : RootStatus.denied;
    notifyListeners();
    if (ok) {
      unawaited(RootShell.initBinder());
      await _pollOnce(force: true);
      _startTimer();
      unawaited(_checkForUpdate());
      unawaited(_checkForKernelUpdate());
      unawaited(_refreshInstalledModulesVersion());
      unawaited(_refreshSlotInfo());
      unawaited(_refreshRebootPending());
      unawaited(_refreshBootLoadEnabled());
    } else {
      _startRootRecheckTimer();
    }
  }

  // ── Boot-time module autoload toggle ─────────────────────────────────────

  bool bootLoadEnabled = false;
  bool bootLoadBusy = false;

  Future<void> _refreshBootLoadEnabled() async {
    final v = await _repo.bootLoadEnabled();
    if (_disposed) return;
    bootLoadEnabled = v;
    notifyListeners();
  }

  Future<void> setBootLoadEnabled(bool value) async {
    if (bootLoadBusy || bootLoadEnabled == value) return;
    bootLoadBusy = true;
    notifyListeners();
    try {
      await _repo.setBootLoadEnabled(value);
      bootLoadEnabled = await _repo.bootLoadEnabled();
    } finally {
      bootLoadBusy = false;
      notifyListeners();
    }
  }

  // ── Self-update (GitHub Releases, independent of the module zip) ────────

  UpdateInfo? availableUpdate;

  Future<void> _checkForUpdate() async {
    final update = await _updates.check();
    if (update != null) {
      availableUpdate = update;
      notifyListeners();
    }
  }

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

  // ── Combined update (App APK + Kernel/OOT-modules) in one Install flow ────

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
  /// from an install done earlier this boot.
  bool get anyUpdateAvailable =>
      rebootPending || availableUpdate != null || kernelUpdateAvailable;

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

  Future<void> _refreshInstalledModulesVersion() async {
    final v = await _repo.installedModulesVersionCode();
    if (_disposed) return;
    installedModulesVersionCode = v;
    notifyListeners();
  }

  Future<void> _checkForKernelUpdate() async {
    final info = await _updates.checkKernel();
    if (_disposed) return;
    if (info != null) {
      availableKernelUpdate = info;
      notifyListeners();
    }
  }

  /// Downloads and installs everything available in one pass: the kernel
  /// OOT-modules zip (via KernelSU/Magisk; the kernel zip is dropped in
  /// /sdcard/Download for a manual flash), then the app APK. Modules go first
  /// (they can't kill us); the APK is last because `pm install` may restart the
  /// app. A reboot afterwards activates the modules. UI reads [updateTasks] /
  /// [updatePhase]; nothing is flashed to the boot image by the app.
  Future<void> installAllUpdates() async {
    if (combinedUpdateBusy) return;
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
      if (app != null) {
        final task = updateTasks.firstWhere((t) => !t.isKernel);
        apkFile = await _updates.download(app.apkUrl, onProgress: (r, t) {
          task.downloadProgress = t > 0 ? r / t : null;
          notifyListeners();
        });
        task.downloadProgress = 1;
        notifyListeners();
      }

      // ── Install phase ──
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
      if (app != null && apkFile != null) {
        final err = await _installApk(apkFile);
        if (err != null) throw Exception(err);
        updateTasks.firstWhere((t) => !t.isKernel).installed = true;
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

  void setForeground(bool value) {
    _foreground = value;
    if (!value) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (rootStatus == RootStatus.granted) {
      _startTimer();
      _pollOnce(force: true);
    } else {
      _startRootRecheckTimer();
    }
  }

  // Adaptive foreground poll cadence: 1s while things are changing or just
  // after an action, easing out to 5s while nothing changes — fewer idle
  // wakeups without hurting how live a newly-plugged adapter feels.
  static const Duration _fastPoll = Duration(seconds: 1);
  Duration _pollInterval = _fastPoll;

  void _startTimer() {
    if (_disposed) return;
    _pollInterval = _fastPoll;
    _armPollTimer();
  }

  /// (Re)arms the single poll timer for the current [_pollInterval]. Self-cancels
  /// first, so it's always safe to call — a forced poll, a resume, or a detected
  /// change re-arm it to reset the cadence.
  void _armPollTimer() {
    _timer?.cancel();
    if (_disposed || !_foreground || rootStatus != RootStatus.granted) return;
    _timer = Timer(_pollInterval, () async {
      await _pollOnce();
      _armPollTimer();
    });
  }

  /// Manual "Check again" from the root-denied screen — gives immediate
  /// feedback instead of waiting out the 2s background re-check tick.
  bool recheckingRoot = false;

  Future<void> recheckRoot() async {
    if (rootStatus == RootStatus.granted || recheckingRoot) return;
    recheckingRoot = true;
    notifyListeners();
    final ok = await RootShell.checkRoot();
    recheckingRoot = false;
    if (ok) {
      rootStatus = RootStatus.granted;
      notifyListeners();
      unawaited(RootShell.initBinder());
      await _pollOnce(force: true);
      _startTimer();
      unawaited(_checkForUpdate());
      unawaited(_checkForKernelUpdate());
      unawaited(_refreshInstalledModulesVersion());
      unawaited(_refreshSlotInfo());
      unawaited(_refreshRebootPending());
      unawaited(_refreshBootLoadEnabled());
    } else {
      notifyListeners();
    }
  }

  /// While root hasn't been granted yet there's nothing to show a button for
  /// — just keep quietly checking so the app transitions on its own the
  /// moment the user grants it in their manager and comes back.
  void _startRootRecheckTimer() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!_foreground) return;
      final ok = await RootShell.checkRoot();
      if (ok) {
        rootStatus = RootStatus.granted;
        notifyListeners();
        await _pollOnce(force: true);
        _startTimer();
        unawaited(_refreshBootLoadEnabled());
      }
    });
  }

  // Held true while a page transition animates: a poll landing mid-swipe
  // would notifyListeners → rebuild both screens on that frame, stalling the
  // nav-bar/page animation. Set via [setPollPaused] from the shell.
  bool _pollPaused = false;

  void setPollPaused(bool value) {
    if (_pollPaused == value) return;
    _pollPaused = value;
    // Catch up once the transition ends — non-force so that if another scroll
    // starts immediately, this scan is dropped instead of rebuilding mid-swipe.
    if (!value && !_disposed) _pollOnce();
  }

  Future<void> _pollOnce({bool force = false}) async {
    if (!_foreground && !force) return;
    if (_pollPaused && !force) return;
    if (_polling || wifiBusy || moduleBusy.isNotEmpty) return;
    _polling = true;
    try {
      final next = await _repo.scan();
      // Dropped if a transition began while the scan was in flight — the
      // resume-time forced poll will pick the change back up.
      if (_pollPaused && !force) return;
      final changed = next.fingerprint != _lastFingerprint;
      if (force || changed) {
        _lastFingerprint = next.fingerprint;
        state = next;
        notifyListeners();
      }
      _pollInterval = nextPollInterval(_pollInterval, changed: changed || force);
    } catch (_) {
      // Transient — the next tick retries.
    } finally {
      _polling = false;
    }
    // A forced poll (action / resume / pull-to-refresh) snaps the cadence back
    // to fast right away instead of waiting out a slow tick.
    if (force && !_disposed) _armPollTimer();
  }

  /// Pull-to-refresh handler.
  Future<void> refresh() => _pollOnce(force: true);

  // ── Actions ─────────────────────────────────────────────────────────────

  /// The last dmesg tail captured by a failed Wi-Fi mode switch (either
  /// direction), so the UI can offer to show/copy it instead of just
  /// "didn't work".
  String? lastWifiSwitchDiagnostics;

  /// True once qca_cld3's PCIe link has dropped for good — only a reboot
  /// brings it back, so the UI shows a persistent reboot prompt.
  bool lastSwitchNeedsReboot = false;

  /// Set the instant a switch is requested and cleared when it settles, so
  /// the UI can flip the toggle immediately instead of waiting out the
  /// round-trip behind a spinner — [wifiBusy] still guards re-entrancy, this
  /// is purely what the hero card renders while that's in flight.
  WifiMode? optimisticWifiMode;

  /// Returns an error string on failure, or null on success.
  Future<String?> setWifiMode(WifiMode target) async {
    if (wifiBusy) return null;

    // No software path back to stock on this hardware — go straight to the
    // reboot prompt instead of attempting a doomed teardown.
    if (target == WifiMode.stock) {
      lastWifiSwitchDiagnostics = null;
      lastSwitchNeedsReboot = true;
      optimisticWifiMode = null;
      notifyListeners();
      return null;
    }

    wifiBusy = true;
    optimisticWifiMode = target;
    notifyListeners();
    String? error;
    try {
      final result = await _repo.switchToInject(state.modules);
      if (!result.stdout.contains('OK_INJECT')) {
        lastWifiSwitchDiagnostics = _repo.dmesgTail(result);
        lastSwitchNeedsReboot = false;
        error = 'Failed to load cfg80211: ${result.errorSummary}';
      } else {
        lastWifiSwitchDiagnostics = null;
        lastSwitchNeedsReboot = false;
      }
    } on ModulePrecondition catch (e) {
      error = e.message;
    } catch (e) {
      error = 'Error: $e';
    } finally {
      wifiBusy = false;
      optimisticWifiMode = null;
      await _pollOnce(force: true);
    }
    return error;
  }

  /// Disarm a pending return-to-stock (the Stock segment armed for reboot)
  /// without running any switch — the device is still in Inject mode, so
  /// tapping Inject just slides the tablet back.
  void cancelStockReboot() {
    if (!lastSwitchNeedsReboot) return;
    lastSwitchNeedsReboot = false;
    notifyListeners();
  }

  /// Fire-and-forget: the persistent root session dies along with the
  /// device on reboot, so this never gets a real reply — that's expected.
  Future<void> rebootDevice() async {
    try {
      await _repo.reboot();
    } catch (_) {}
  }

  /// Per-module failure state: module name → the message from its last failed
  /// toggle. Drives the tappable error icon on that row; tapping it fetches the
  /// dmesg on demand ([fetchModuleDmesg]). Never pops a modal dialog and never
  /// blocks toggling any other module.
  final Map<String, String> moduleErrors = {};

  /// Same idea as [optimisticWifiMode] but per module name, so each row's
  /// switch flips the instant it's tapped instead of showing a spinner
  /// until the root round-trip comes back.
  final Map<String, bool> optimisticModuleLoaded = {};

  Future<String?> toggleModule(ModuleInfo module, bool want) async {
    if (moduleBusy.contains(module.name)) return null;
    moduleBusy.add(module.name);
    moduleErrors.remove(module.name); // clear any prior error when retried
    optimisticModuleLoaded[module.name] = want;
    notifyListeners();
    String? error;
    try {
      final result = await _repo.setLoaded(module, want);
      final after = await _repo.scan();
      state = after;
      _lastFingerprint = after.fingerprint;
      final now = after.modules.firstWhere(
        (m) => m.name == module.name,
        orElse: () => module,
      );
      if (now.loaded != want) {
        error = '${want ? 'Failed to load' : 'Failed to unload'} ${module.name}: '
            '${_repo.loadErrorSummary(result)}';
      }
    } on ModulePrecondition catch (e) {
      error = e.message;
    } catch (e) {
      error = 'Error: $e';
    } finally {
      if (error != null) moduleErrors[module.name] = error;
      moduleBusy.remove(module.name);
      optimisticModuleLoaded.remove(module.name);
      notifyListeners();
    }
    return error;
  }

  /// Fetches a module's dmesg tail on demand — only when the user taps its
  /// error icon, so a failed toggle never holds the serialized root shell
  /// collecting logs (which used to stall the next module's toggle).
  Future<String> fetchModuleDmesg(ModuleInfo module) => _repo.moduleDmesg(module);

  /// Debug bundle (last_kmsg + dmesg + logcat) for the Settings ▸ Debug block.
  /// Lands in the app's own internal files dir so it's readable without root.
  Future<String?> collectDebugLogs() async {
    final dir = await NativeBridge.filesDir();
    if (dir == null) return null;
    return _repo.collectDebugLogs(dir);
  }

  Future<void> deleteDebugLogs(String path) => _repo.deleteDebugLogs(path);

  // ── Dependency-aware load / unload ──────────────────────────────────────

  ModuleInfo? _moduleByName(String name) {
    for (final m in state.modules) {
      if (m.name == name) return m;
    }
    return null;
  }

  Set<String> get _availableNames => {for (final m in state.modules) m.name};
  Set<String> get _loadedNames =>
      {for (final m in state.modules) if (m.loaded) m.name};

  /// What flipping [module] on needs right now: dependencies to load first, or
  /// (for a Wi-Fi driver in Stock mode) Inject mode to be enabled.
  DependencyPlan planFor(ModuleInfo module) => planModuleLoad(
        target: module.name,
        available: _availableNames,
        loaded: _loadedNames,
        injectActive: state.wifiMode == WifiMode.inject,
      );

  /// Currently-loaded modules that depend on [module] — the ones an `rmmod`
  /// would otherwise fail on with "Module is in use".
  List<String> loadedDependentsOf(ModuleInfo module) => loadedDependents(
        target: module.name,
        available: _availableNames,
        loaded: _loadedNames,
      );

  /// Loads [depNames] (in order) then [target] in a single root round-trip,
  /// surfacing an error on whichever module actually failed.
  Future<String?> loadModuleWithDeps(
      ModuleInfo target, List<String> depNames) {
    final ordered = <ModuleInfo>[
      for (final n in depNames)
        _moduleByName(n) ??
            ModuleInfo(name: n, loaded: false, isWifiClass: false),
      target,
    ];
    return _runChain(ordered, load: true, primary: target.name);
  }

  /// Unloads [dependents] (in order) then [target].
  Future<String?> unloadModuleWithDependents(
      ModuleInfo target, List<String> dependents) {
    final ordered = <ModuleInfo>[
      for (final n in dependents)
        _moduleByName(n) ??
            ModuleInfo(name: n, loaded: true, isWifiClass: false),
      target,
    ];
    return _runChain(ordered, load: false, primary: target.name);
  }

  Future<String?> _runChain(
    List<ModuleInfo> ordered, {
    required bool load,
    required String primary,
  }) async {
    final names = ordered.map((m) => m.name).toList();
    if (names.any(moduleBusy.contains)) return null;
    for (final n in names) {
      moduleBusy.add(n);
      moduleErrors.remove(n);
      optimisticModuleLoaded[n] = load;
    }
    notifyListeners();
    String? error;
    try {
      final result =
          await (load ? _repo.loadChain(ordered) : _repo.unloadChain(ordered));
      final after = await _repo.scan();
      state = after;
      _lastFingerprint = after.fingerprint;
      final failed = _repo.chainFailure(result);
      if (failed != null) {
        error = '${load ? 'Failed to load' : 'Failed to unload'} $failed: '
            '${_repo.loadErrorSummary(result)}';
        moduleErrors[failed] = error;
      }
    } catch (e) {
      error = 'Error: $e';
      moduleErrors[primary] = error;
    } finally {
      for (final n in names) {
        moduleBusy.remove(n);
        optimisticModuleLoaded.remove(n);
      }
      notifyListeners();
    }
    return error;
  }

  Future<String?> loadAdapter(DetectedAdapter adapter) async {
    final driver = adapter.match?.driver;
    if (driver == null) return null;
    if (state.wifiMode != WifiMode.inject) {
      return 'Enable Inject mode on the Overview screen first.';
    }
    ModuleInfo? mod;
    for (final m in state.modules) {
      if (m.name == driver) {
        mod = m;
        break;
      }
    }
    if (mod == null) return "Driver $driver isn't staged in this module.";
    final err = await toggleModule(mod, true);
    // On a clean load the interface comes up managed already, so just hand it
    // to the framework (no driver reload needed) so stock Settings can use it.
    if (err == null) {
      await reconfigureAdapter(chipsetDriver: driver, reloadDriver: false);
    }
    return err;
  }

  /// True while a Reconfigure round-trip is in flight, so the button can show a
  /// loader and guard against re-entry.
  bool reconfiguring = false;

  /// USB Wi-Fi chipset drivers — used to tell an external adapter's interface
  /// apart from the internal Wi-Fi and to pick what Reconfigure reloads.
  static const Set<String> _chipsetDrivers = {
    '88XXau', '8188eu', '8814au', '88x2bu',
  };

  /// The loaded USB Wi-Fi chipset driver, if any (first match).
  String? get loadedAdapterDriver {
    for (final m in state.modules) {
      if (m.loaded && _chipsetDrivers.contains(m.name)) return m.name;
    }
    return null;
  }

  /// Live wireless interfaces backed by an external adapter — the candidates the
  /// Reconfigure flow can initialise. One → run directly; more than one → the UI
  /// offers a "Select interface" picker.
  ///
  /// Matching on the sysfs driver name alone is fragile (the USB driver often
  /// registers a variant like `rtl88xxau` rather than the `.ko` basename), so in
  /// Inject mode — where the internal Wi-Fi chip is torn down — treat every live
  /// `wlanX` as an external adapter. Outside Inject mode, fall back to the exact
  /// chipset-driver match so the built-in interface is never picked up.
  List<WifiInterface> get adapterInterfaces => [
        for (final i in state.interfaces)
          if (_chipsetDrivers.contains(i.driver) ||
              (state.wifiMode == WifiMode.inject && i.name.startsWith('wlan')))
            i,
      ];

  /// Re-hand an adapter to the Android Wi-Fi framework as a managed station.
  /// Pass [iface] to target a specific interface (the picker's choice); with
  /// none, it resolves from [chipsetDriver] or the first adapter interface.
  /// [reloadDriver] forces a chipset reload (to clear a monitor VIF); left null
  /// it reloads only when the target interface is actually in monitor mode.
  /// Returns an error string on failure, or null on success.
  Future<String?> reconfigureAdapter({
    WifiInterface? iface,
    String? chipsetDriver,
    bool? reloadDriver,
  }) async {
    if (reconfiguring) return null;

    // Resolve which interface to initialise: explicit pick, else the one bound
    // to the given driver, else the first external adapter interface.
    WifiInterface? target = iface;
    if (target == null) {
      for (final i in adapterInterfaces) {
        if (chipsetDriver != null && i.driver == chipsetDriver) {
          target = i;
          break;
        }
      }
      if (target == null && adapterInterfaces.isNotEmpty) {
        target = adapterInterfaces.first;
      }
    }

    // For a driver reload we need the real .ko basename (e.g. "88XXau"), not the
    // sysfs driver-name variant an interface reports — so prefer the explicit
    // arg / the loaded chipset module, and only fall back to the iface's driver.
    final driver = chipsetDriver ??
        loadedAdapterDriver ??
        (target != null && target.driver.isNotEmpty ? target.driver : null);
    if (driver == null || driver.isEmpty) {
      return 'No Wi-Fi adapter driver is loaded to reconfigure.';
    }
    final targetName = target?.name ?? 'wlan0';
    final reload = reloadDriver ?? (target?.monitor ?? false);

    reconfiguring = true;
    notifyListeners();
    String? error;
    try {
      final r = await _repo.reconfigureManaged(
        chipsetDriver: driver,
        iface: targetName,
        reloadDriver: reload,
      );
      if (r.stdout.contains('NO_IFACE') || !r.stdout.contains('OK_RECONFIG')) {
        error = 'Reconfigure could not bring up the interface: ${r.errorSummary}';
      }
    } catch (e) {
      error = 'Error: $e';
    } finally {
      reconfiguring = false;
      // Broadcast immediately — don't rely on _pollOnce to clear the button's
      // loader, since it early-returns when a periodic poll is already in flight
      // (or when nothing changed), which left the spinner stuck forever.
      notifyListeners();
      await _pollOnce(force: true);
    }
    return error;
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

/// Adaptive foreground-poll cadence: snap back to [fast] the instant something
/// changed, otherwise ease out one step (1s) toward [slow]. Pure for testing.
Duration nextPollInterval(
  Duration current, {
  required bool changed,
  Duration fast = const Duration(seconds: 1),
  Duration slow = const Duration(seconds: 5),
}) {
  if (changed) return fast;
  final next = current + const Duration(seconds: 1);
  return next > slow ? slow : next;
}
