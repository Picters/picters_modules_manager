import 'package:flutter/foundation.dart';

import 'perf_info.dart';
import 'perf_repository.dart';

/// Owns the Performance tab: the live CPU/GPU cap state, the selected profile
/// and the boot-persist flag. Its own notifier so the Performance screen
/// rebuilds only on its own changes, not the 1s system scan.
class PerfController extends ChangeNotifier {
  PerfController([PerfRepository? repo]) : _repo = repo ?? PerfRepository();

  final PerfRepository _repo;
  bool _disposed = false;

  PerfState state = PerfState.empty;
  bool busy = false;
  String? lastError;

  /// The active profile — from the persisted config, defaulting to Full (stock)
  /// when nothing has been applied yet.
  PerfProfile get profile => state.profile ?? PerfProfile.full;
  bool get persistOnBoot => state.persistOnBoot;

  /// False when the device exposes no cpufreq policies (nothing to control).
  bool get supported => state.clusters.isNotEmpty;

  Future<void> init() => refresh();

  Future<void> refresh() async {
    final s = await _repo.scan();
    if (_disposed) return;
    state = s;
    notifyListeners();
  }

  Future<void> setProfile(PerfProfile p) async {
    if (busy) return;
    busy = true;
    lastError = null;
    notifyListeners();
    try {
      final r = await _repo.applyProfile(
        profile: p,
        state: state,
        persistOnBoot: state.persistOnBoot,
      );
      if (!r.stdout.contains('OK_PERF')) {
        lastError = 'Could not apply the profile: ${r.errorSummary}';
      }
      await refresh();
    } catch (e) {
      lastError = 'Error: $e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> setPersistOnBoot(bool value) async {
    if (busy || state.persistOnBoot == value) return;
    busy = true;
    notifyListeners();
    try {
      await _repo.applyProfile(
        profile: profile,
        state: state,
        persistOnBoot: value,
      );
      await refresh();
    } catch (e) {
      lastError = 'Error: $e';
    } finally {
      busy = false;
      notifyListeners();
    }
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
