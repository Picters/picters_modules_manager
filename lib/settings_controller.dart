import 'package:flutter/foundation.dart';

import 'module_repository.dart';
import 'native_bridge.dart';

/// Owns the Settings tab's state: the boot-time auto-load flag and the debug-log
/// bundler. Split out of [AppController] so the Settings screen rebuilds only on
/// its own changes, not on every 1s system scan or Wi-Fi/module action.
class SettingsController extends ChangeNotifier {
  SettingsController(this._repo);

  final ModuleRepository _repo;
  bool _disposed = false;

  // ── Boot-time module autoload toggle ─────────────────────────────────────

  bool bootLoadEnabled = false;
  bool bootLoadBusy = false;

  /// Hides the Performance tab when true.
  bool hidePerformance = false;

  /// True once the persisted flags have been read at least once. The shell holds
  /// the first paint of the tab chrome until this flips, so the Performance tab
  /// is never shown-then-collapsed (no startup jerk).
  bool loaded = false;

  /// Reads the persisted flags. Called once root is granted.
  Future<void> init() async {
    await Future.wait([
      _refreshBootLoadEnabled(),
      _refreshHidePerformance(),
    ]);
    loaded = true;
    notifyListeners();
  }

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

  Future<void> _refreshHidePerformance() async {
    final v = await _repo.hidePerformance();
    if (_disposed) return;
    hidePerformance = v;
    notifyListeners();
  }

  /// Toggles the Performance tab. Optimistic so the tab list flips instantly.
  Future<void> setHidePerformance(bool value) async {
    if (hidePerformance == value) return;
    hidePerformance = value;
    notifyListeners();
    await _repo.setHidePerformance(value);
  }

  // ── Debug log bundle ─────────────────────────────────────────────────────

  /// Debug bundle (last_kmsg + dmesg + logcat) for the Settings ▸ Debug block.
  /// Lands in the app's own internal files dir so it's readable without root.
  Future<String?> collectDebugLogs() async {
    final dir = await NativeBridge.filesDir();
    if (dir == null) return null;
    return _repo.collectDebugLogs(dir);
  }

  Future<void> deleteDebugLogs(String path) => _repo.deleteDebugLogs(path);

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
