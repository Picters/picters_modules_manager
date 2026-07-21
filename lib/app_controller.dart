import 'dart:async';

import 'package:flutter/foundation.dart';

import 'module_dependencies.dart';
import 'module_info.dart';
import 'module_repository.dart';
import 'perf_controller.dart';
import 'root_shell.dart';
import 'settings_controller.dart';
import 'update_controller.dart';
import 'usb_devices.dart';

enum RootStatus { checking, granted, denied }

/// Single source of truth for the live system view — root status, the 1-second
/// poll and every Wi-Fi/module/adapter action. Update delivery and Settings
/// state live in their own notifiers ([update], [settings]) so those screens
/// don't rebuild on the scan; everything here funnels through the persistent
/// root shell, so a poll is one cheap round-trip.
class AppController extends ChangeNotifier {
  AppController(ModuleRepository repo)
      : _repo = repo,
        update = UpdateController(repo),
        settings = SettingsController(repo),
        perf = PerfController();

  final ModuleRepository _repo;

  /// Update flow (self-update APK + kernel/OOT-modules build). Its own notifier
  /// so the update dialog and app-bar pill don't rebuild on the 1s system scan.
  final UpdateController update;

  /// Settings tab state (boot-load flag, debug-log bundler), likewise isolated.
  final SettingsController settings;

  /// Performance tab state (CPU/GPU frequency caps), likewise isolated.
  final PerfController perf;

  RootStatus rootStatus = RootStatus.checking;
  SystemState state = SystemState.empty;

  /// False when the running kernel isn't a Picters build — drives the standing
  /// warning banner (injection / modules aren't guaranteed on a foreign kernel).
  bool onPictersKernel = true;

  Future<void> _checkKernelAuthentic() async {
    final r = await _repo.kernelRelease();
    if (_disposed) return;
    final ok = r.toLowerCase().contains('picters');
    if (ok == onPictersKernel) return;
    onPictersKernel = ok;
    notifyListeners();
  }

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
      unawaited(update.init());
      unawaited(settings.init());
      unawaited(perf.init());
      unawaited(_checkKernelAuthentic());
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
      unawaited(update.init());
      unawaited(settings.init());
      unawaited(perf.init());
      unawaited(_checkKernelAuthentic());
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
        unawaited(settings.init());
        unawaited(perf.init());
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

    wifiBusy = true;
    optimisticWifiMode = target;
    lastSwitchNeedsReboot = false;
    notifyListeners();
    String? error;
    try {
      if (target == WifiMode.stock) {
        // Live return to stock — the cnss2/PCIe stack stayed up through Inject,
        // so reloading the vendor Wi-Fi modules brings the built-in chip back
        // without a reboot. If it can't, arm the reboot fallback.
        final result = await _repo.switchToStock(state.modules);
        if (result.stdout.contains('OK_STOCK')) {
          lastWifiSwitchDiagnostics = null;
        } else {
          lastWifiSwitchDiagnostics = _repo.dmesgTail(result);
          lastSwitchNeedsReboot = true;
          error = 'Could not restore stock Wi-Fi live — reboot to finish.';
        }
      } else {
        final result = await _repo.switchToInject(state.modules);
        if (!result.stdout.contains('OK_INJECT')) {
          lastWifiSwitchDiagnostics = _repo.dmesgTail(result);
          error = 'Failed to load cfg80211: ${result.errorSummary}';
        } else {
          lastWifiSwitchDiagnostics = null;
        }
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

  /// Enables rndis_host via the cdc_ether swap (see [ModuleRepository.enableRndisHost]).
  /// A plain toggle would fail with "Unknown symbol", so this is its own path.
  Future<String?> enableRndisHost(ModuleInfo module) async {
    const ce = 'cdc_ether';
    if (moduleBusy.contains(module.name) || moduleBusy.contains(ce)) return null;
    moduleBusy.add(module.name);
    moduleBusy.add(ce);
    moduleErrors.remove(module.name);
    optimisticModuleLoaded[module.name] = true;
    notifyListeners();
    String? error;
    try {
      final r = await _repo.enableRndisHost();
      final after = await _repo.scan();
      state = after;
      _lastFingerprint = after.fingerprint;
      if (!r.stdout.contains('OK_RNDIS')) {
        error = 'Failed to enable rndis_host: ${_repo.loadErrorSummary(r)}';
        moduleErrors[module.name] = error;
      }
    } catch (e) {
      error = 'Error: $e';
      moduleErrors[module.name] = error;
    } finally {
      moduleBusy.remove(module.name);
      moduleBusy.remove(ce);
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
    update.dispose();
    settings.dispose();
    perf.dispose();
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
