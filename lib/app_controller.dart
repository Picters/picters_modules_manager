import 'dart:async';

import 'package:flutter/foundation.dart';

import 'module_info.dart';
import 'module_repository.dart';
import 'root_shell.dart';
import 'update_checker.dart';
import 'usb_devices.dart';

enum RootStatus { checking, granted, denied }

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
      await _pollOnce(force: true);
      _startTimer();
      unawaited(_checkForUpdate());
    } else {
      _startRootRecheckTimer();
    }
  }

  // ── Self-update (GitHub Releases, independent of the module zip) ────────

  UpdateInfo? availableUpdate;
  bool updateBusy = false;
  double? updateProgress;

  Future<void> _checkForUpdate() async {
    final update = await _updates.check();
    if (update != null) {
      availableUpdate = update;
      notifyListeners();
    }
  }

  /// Downloads the release APK and installs it via root — returns an error
  /// string on failure, or null on success (`pm install` succeeding here
  /// swaps the running app out from under itself; the caller doesn't need to
  /// do anything further).
  Future<String?> downloadAndInstallUpdate() async {
    final update = availableUpdate;
    if (update == null || updateBusy) return null;
    updateBusy = true;
    updateProgress = null;
    notifyListeners();
    try {
      final apk = await _updates.download(
        update.apkUrl,
        onProgress: (received, total) {
          updateProgress = total > 0 ? received / total : null;
          notifyListeners();
        },
      );
      // Stream the bytes into pm via stdin rather than `pm install <path>`:
      // the APK lives in the app's private cache, which installd (running as
      // system, not root) can't open — but the root shell can read it fine and
      // pipe it in, so `-S <size> -` sidesteps the permission problem entirely.
      final size = await apk.length();
      final result = await RootShell.run(
        "cat '${apk.path}' | pm install -r -S $size -",
        timeout: const Duration(seconds: 120),
      );
      if (!result.stdout.contains('Success')) {
        return 'Install failed: ${result.errorSummary}';
      }
      availableUpdate = null;
      return null;
    } catch (e) {
      return 'Update failed: $e';
    } finally {
      updateBusy = false;
      updateProgress = null;
      notifyListeners();
    }
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

  void _startTimer() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _pollOnce());
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
      await _pollOnce(force: true);
      _startTimer();
      unawaited(_checkForUpdate());
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
      }
    });
  }

  Future<void> _pollOnce({bool force = false}) async {
    if (!_foreground && !force) return;
    if (_polling || wifiBusy || moduleBusy.isNotEmpty) return;
    _polling = true;
    try {
      final next = await _repo.scan();
      if (force || next.fingerprint != _lastFingerprint) {
        _lastFingerprint = next.fingerprint;
        state = next;
        notifyListeners();
      }
    } catch (_) {
      // Transient — the next tick retries.
    } finally {
      _polling = false;
    }
  }

  /// Pull-to-refresh handler.
  Future<void> refresh() => _pollOnce(force: true);

  // ── Actions ─────────────────────────────────────────────────────────────

  /// The last dmesg tail captured by a failed Wi-Fi mode switch (either
  /// direction), so the UI can offer to show/copy it instead of just
  /// "didn't work".
  String? lastWifiSwitchDiagnostics;

  /// True when the last failed switch was specifically the
  /// vendor-module-won't-reload case: on this hardware, once qca_cld3's PCIe
  /// link drops on rmmod it stays down (config space reads back device ID
  /// 0xffff) — confirmed on-device that neither a plain unbind/bind nor a
  /// real FLR reset of the PCI function brings it back, only the
  /// bootloader's own cold-boot power sequencing does. So this isn't a
  /// "keep retrying" case — the UI shows a persistent reboot prompt instead
  /// of the normal hero card until the user reboots or switches away again.
  bool lastSwitchNeedsReboot = false;

  /// Set the instant a switch is requested and cleared when it settles, so
  /// the UI can flip the toggle immediately instead of waiting out the
  /// round-trip behind a spinner — [wifiBusy] still guards re-entrancy, this
  /// is purely what the hero card renders while that's in flight.
  WifiMode? optimisticWifiMode;

  /// Returns an error string on failure, or null on success.
  Future<String?> setWifiMode(WifiMode target) async {
    if (wifiBusy) return null;
    wifiBusy = true;
    optimisticWifiMode = target;
    notifyListeners();
    String? error;
    try {
      final result = target == WifiMode.nethunter
          ? await _repo.switchToNetHunter(state.modules)
          : await _repo.switchToStock(state.modules);
      if (target == WifiMode.stock && !_repo.stockRestored(result)) {
        lastWifiSwitchDiagnostics = _repo.dmesgTail(result);
        lastSwitchNeedsReboot = true;
        error = "Couldn't restore stock Wi-Fi automatically.";
      } else if (target == WifiMode.nethunter && !result.stdout.contains('OK_NH')) {
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

  /// Fire-and-forget: the persistent root session dies along with the
  /// device on reboot, so this never gets a real reply — that's expected.
  Future<void> rebootDevice() async {
    try {
      await _repo.reboot();
    } catch (_) {}
  }

  /// The last dmesg tail captured by a failed module load/unload — same idea
  /// as [lastWifiSwitchDiagnostics], for the per-module toggle path.
  String? lastModuleDiagnostics;

  /// Same idea as [optimisticWifiMode] but per module name, so each row's
  /// switch flips the instant it's tapped instead of showing a spinner
  /// until the root round-trip comes back.
  final Map<String, bool> optimisticModuleLoaded = {};

  Future<String?> toggleModule(ModuleInfo module, bool want) async {
    if (moduleBusy.contains(module.name)) return null;
    moduleBusy.add(module.name);
    optimisticModuleLoaded[module.name] = want;
    notifyListeners();
    String? error;
    try {
      final result = await _repo.setLoaded(module, want, state.modules);
      final after = await _repo.scan();
      state = after;
      _lastFingerprint = after.fingerprint;
      final now = after.modules.firstWhere(
        (m) => m.name == module.name,
        orElse: () => module,
      );
      if (now.loaded != want) {
        lastModuleDiagnostics = _repo.dmesgTail(result);
        error = '${want ? 'Failed to load' : 'Failed to unload'} ${module.name}: '
            '${_repo.loadErrorSummary(result)}';
      } else {
        lastModuleDiagnostics = null;
      }
    } on ModulePrecondition catch (e) {
      error = e.message;
    } catch (e) {
      error = 'Error: $e';
    } finally {
      moduleBusy.remove(module.name);
      optimisticModuleLoaded.remove(module.name);
      notifyListeners();
    }
    return error;
  }

  Future<String?> loadAdapter(DetectedAdapter adapter) async {
    final driver = adapter.match?.driver;
    if (driver == null) return null;
    if (state.wifiMode != WifiMode.nethunter) {
      return 'Enable NetHunter Wi-Fi on the Overview screen first.';
    }
    ModuleInfo? mod;
    for (final m in state.modules) {
      if (m.name == driver) {
        mod = m;
        break;
      }
    }
    if (mod == null) return "Driver $driver isn't staged in this module.";
    return toggleModule(mod, true);
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
