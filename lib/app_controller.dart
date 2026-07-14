import 'dart:async';

import 'package:flutter/foundation.dart';

import 'module_info.dart';
import 'module_repository.dart';
import 'root_shell.dart';
import 'usb_devices.dart';

enum RootStatus { checking, granted, denied }

/// Single source of truth for the UI. Owns the 1-second live poll, the root
/// status, and all the mutating actions. Everything is funnelled through the
/// persistent root shell, so a poll is one cheap round-trip.
class AppController extends ChangeNotifier {
  AppController(this._repo);

  final ModuleRepository _repo;

  RootStatus rootStatus = RootStatus.checking;
  SystemState state = SystemState.empty;

  bool wifiBusy = false;
  final Set<String> moduleBusy = {};

  Timer? _timer;
  bool _foreground = true;
  bool _polling = false;
  String _lastFingerprint = '';

  Future<void> init() async {
    rootStatus = RootStatus.checking;
    notifyListeners();
    final ok = await RootShell.checkRoot();
    rootStatus = ok ? RootStatus.granted : RootStatus.denied;
    notifyListeners();
    if (ok) {
      await _pollOnce(force: true);
      _startTimer();
    } else {
      _startRootRecheckTimer();
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
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _pollOnce());
  }

  /// While root hasn't been granted yet there's nothing to show a button for
  /// — just keep quietly checking so the app transitions on its own the
  /// moment the user grants it in their manager and comes back.
  void _startRootRecheckTimer() {
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

  /// Returns an error string on failure, or null on success.
  Future<String?> setWifiMode(WifiMode target) async {
    if (wifiBusy) return null;
    wifiBusy = true;
    notifyListeners();
    String? error;
    try {
      final result = target == WifiMode.nethunter
          ? await _repo.switchToNetHunter(state.modules)
          : await _repo.switchToStock(state.modules);
      if (target == WifiMode.stock && !_repo.stockRestored(result)) {
        error = "Couldn't restore stock Wi-Fi automatically — reboot to restore it.";
      } else if (target == WifiMode.nethunter && !result.stdout.contains('OK_NH')) {
        error = 'Failed to load cfg80211: ${result.errorSummary}';
      }
    } on ModulePrecondition catch (e) {
      error = e.message;
    } catch (e) {
      error = 'Error: $e';
    } finally {
      wifiBusy = false;
      await _pollOnce(force: true);
    }
    return error;
  }

  Future<String?> toggleModule(ModuleInfo module, bool want) async {
    if (moduleBusy.contains(module.name)) return null;
    moduleBusy.add(module.name);
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
        error = '${want ? 'Failed to load' : 'Failed to unload'} ${module.name}: '
            '${result.errorSummary}';
      }
    } on ModulePrecondition catch (e) {
      error = e.message;
    } catch (e) {
      error = 'Error: $e';
    } finally {
      moduleBusy.remove(module.name);
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
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
