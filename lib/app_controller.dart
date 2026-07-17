import 'dart:async';

import 'package:flutter/foundation.dart';

import 'module_dependencies.dart';
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
      unawaited(RootShell.initBinder());
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
      // Copy the APK into /data/local/tmp — a spot the platform installer
      // (installd, running as system, not root) can actually read, unlike the
      // app's private cache — then install by path. `-d` allows a same/older
      // versionCode so the update isn't refused as a "downgrade". A signature
      // mismatch (e.g. a locally debug-signed build vs the release key) can't
      // be auto-resolved and is reported clearly instead.
      const dest = '/data/local/tmp/pmm_update.apk';
      final result = await RootShell.run(
        "cp '${apk.path}' '$dest' && chmod 644 '$dest' && "
        "pm install -r -d '$dest'; rm -f '$dest'",
        timeout: const Duration(seconds: 120),
      );
      try {
        await apk.delete();
      } catch (_) {}
      if (!result.stdout.contains('Success')) {
        return _installErrorMessage(result);
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

  /// Turns a failed `pm install` into a message that names the actual reason,
  /// mapping the common INSTALL_FAILED_* codes to plain language. Without this
  /// the UI showed whatever line `pm` printed last — usually a bare Binder
  /// stack frame — which told the user nothing.
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

    // Restoring the stock vendor stack is impossible without a cold reboot on
    // this hardware: once qca_cld3 is torn down the WLAN PCIe link stays down
    // (config space reads back 0xffff within ~2s; no unbind/bind or FLR reset
    // brings it back — only the bootloader's cold-boot power sequencing does).
    // So there's nothing to "switch" to and no point spinning through a doomed
    // teardown — go straight to the honest reboot prompt. A reboot restores
    // stock cleanly: every OOT module unloads on boot and the vendor stack
    // comes up normally.
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
