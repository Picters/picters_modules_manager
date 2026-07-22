import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_bottom_bar.dart';
import 'app_controller.dart';
import 'module_repository.dart';
import 'modules_screen.dart';
import 'native_bridge.dart';
import 'overview_screen.dart';
import 'performance_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';
import 'update_checker.dart';
import 'update_controller.dart';
import 'widgets.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

/// Critically damped page spring — settles once with no overshoot, unlike
/// the default underdamped one that oscillates and re-fires onPageChanged.
class _SnappyPagePhysics extends PageScrollPhysics {
  const _SnappyPagePhysics({super.parent});

  @override
  _SnappyPagePhysics applyTo(ScrollPhysics? ancestor) {
    return _SnappyPagePhysics(parent: buildParent(ancestor));
  }

  @override
  SpringDescription get spring =>
      SpringDescription.withDampingRatio(mass: 0.4, stiffness: 220, ratio: 1.0);
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final AppController _controller = AppController(ModuleRepository());
  PageController _pageController = PageController();

  // Pushed USB attach/detach events — refresh the scan the moment an adapter is
  // plugged instead of waiting out the poll interval.
  StreamSubscription<void>? _usbSub;

  // Only the fields the shell chrome needs, so the 1s poll doesn't rebuild
  // the whole Scaffold — the two screens have their own AnimatedBuilders.
  RootStatus _rootStatus = RootStatus.checking;
  bool _hasUpdate = false;
  bool _onPictersKernel = true;
  bool _deviceSupported = true;

  // The active tab as a notifier, NOT setState: only the AppBar title and the
  // nav bar listen to it, so switching tabs never rebuilds the PageView or the
  // two heavy screens. (Doing that mid-swipe was the freeze-then-jump.)
  final ValueNotifier<int> _tab = ValueNotifier(0);

  // The Performance tab can be hidden from Settings; the titles, pages and nav
  // items are built from this.
  bool _hidePerf = false;

  // False until the persisted hide-flag has been read once — the tab chrome is
  // held back until then so it never flashes 4 tabs and collapses to 3.
  bool _settingsReady = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_handleControllerChanged);
    // The update pill lives on its own notifier now, so watch it too.
    _controller.update.addListener(_handleControllerChanged);
    _controller.settings.addListener(_handleSettingsChanged);
    _controller.init();
    _usbSub = NativeBridge.usbEvents().listen((_) {
      if (_controller.rootStatus == RootStatus.granted) _controller.refresh();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _usbSub?.cancel();
    _controller.removeListener(_handleControllerChanged);
    _controller.update.removeListener(_handleControllerChanged);
    _controller.settings.removeListener(_handleSettingsChanged);
    _pageController.dispose();
    _tab.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    final hasUpdate = _controller.update.anyUpdateAvailable;
    final onPicters = _controller.onPictersKernel;
    final deviceSupported = _controller.update.deviceSupported;
    if (_controller.rootStatus != _rootStatus ||
        hasUpdate != _hasUpdate ||
        onPicters != _onPictersKernel ||
        deviceSupported != _deviceSupported) {
      setState(() {
        _rootStatus = _controller.rootStatus;
        _hasUpdate = hasUpdate;
        _onPictersKernel = onPicters;
        _deviceSupported = deviceSupported;
      });
    }
  }

  // Reacts to the Settings controller: the first flag read reveals the chrome
  // (and adopts the tab set silently, leaving the user on Overview); a later
  // user toggle re-indexes and keeps the user on Settings.
  void _handleSettingsChanged() {
    final s = _controller.settings;
    final ready = s.loaded;
    final hide = s.hidePerformance;

    // A genuine user toggle only happens after the first load, when the flag
    // actually flips. Everything else (initial read, becoming ready) just adopts
    // the value without moving the user.
    final userToggle = ready && _settingsReady && hide != _hidePerf;
    if (hide == _hidePerf && ready == _settingsReady) return;

    if (!userToggle) {
      setState(() {
        _hidePerf = hide;
        _settingsReady = ready;
      });
      return;
    }

    // The Performance toggle lives on Settings (the last tab). Hiding/showing it
    // shifts indices, so rebuild with a fresh controller aimed at the Settings
    // tab's new index — the user stays put.
    final settingsIndex = hide ? 2 : 3;
    _pageController.dispose();
    _pageController = PageController(initialPage: settingsIndex);
    setState(() {
      _hidePerf = hide;
      _tab.value = settingsIndex;
    });
    // When the tab set GROWS (un-hiding), initialPage can clamp against the
    // stale, smaller scroll extent and land on the wrong page (Performance) —
    // re-assert the target once the new layout is in.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _pageController.hasClients &&
          _pageController.page?.round() != settingsIndex) {
        _pageController.jumpToPage(settingsIndex);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controller.setForeground(state == AppLifecycleState.resumed);
  }

  bool _programmaticPage = false;
  int _navGen = 0;

  void _goToTab(int i) {
    if (i == _tab.value) return;
    HapticFeedback.selectionClick();
    final gen = ++_navGen;
    _programmaticPage = true;
    _tab.value = i;
    // Slide the whole way from the current page, flying through the ones in
    // between, to the tapped tab — a full page-through animation rather than a
    // jump that starts mid-way.
    _pageController
        .animateToPage(
          i,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeInOut,
        )
        // Only the latest nav clears the flag, so a stale one can't re-arm the
        // swipe haptic mid-animation.
        .then((_) {
          if (gen == _navGen) _programmaticPage = false;
        });
  }

  void _onPageChanged(int i) {
    // Programmatic navigation already set _tab up front; ignore the intermediate
    // page events it fires so the title doesn't flicker through the middle tab.
    if (_programmaticPage) return;
    if (i == _tab.value) return;
    // A finger-swipe (not a nav-bar tap) gets its own haptic tick.
    HapticFeedback.selectionClick();
    _tab.value = i;
  }

  Future<void> _pinShortcut() async {
    HapticFeedback.lightImpact();
    final ok = await confirmAction(
      context,
      title: 'Pin shortcut?',
      message: 'Add a home-screen shortcut for this app?',
      confirmLabel: 'Pin',
    );
    if (!ok || !mounted) return;
    final done = await NativeBridge.requestPinShortcut();
    if (!mounted) return;
    if (done) {
      showInfo(context, 'Shortcut request sent to your launcher.');
    } else {
      showError(context, "Your launcher doesn't support pinned shortcuts.");
    }
  }

  @override
  Widget build(BuildContext context) {
    // Granted but flags not read yet → keep the neutral loader up rather than
    // painting a tab set we're about to change.
    final granted = _rootStatus == RootStatus.granted && _settingsReady;
    final hidePerf = _hidePerf;
    final titles = [
      'Overview',
      'Modules',
      if (!hidePerf) 'Performance',
      'Settings',
    ];
    return Scaffold(
      // The floating bar hovers over the content instead of reserving a strip.
      extendBody: true,
      appBar: AppBar(
        title: granted
            ? ValueListenableBuilder<int>(
                valueListenable: _tab,
                builder: (context, tab, _) =>
                    Text(titles[tab.clamp(0, titles.length - 1)]),
              )
            : const Text('Modules Manager'),
        actions: [
          if (_hasUpdate)
            _UpdatePill(onTap: () => _showUpdateDialog(context, _controller.update)),
          if (granted)
            IconButton(
              icon: const Icon(Icons.add_to_home_screen_outlined),
              tooltip: 'Pin shortcut',
              onPressed: _pinShortcut,
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: switch (_rootStatus) {
        RootStatus.checking => const _CenterGlyph(
          icon: Icons.hourglass_empty,
          title: 'Checking root access…',
          spinner: true,
        ),
        RootStatus.denied => _RootDenied(controller: _controller),
        // Root is in, but hold the neutral loader until the tab flags are read
        // so the chrome appears once, already in its final shape.
        RootStatus.granted when !_settingsReady => const _CenterGlyph(
          icon: Icons.hourglass_empty,
          title: 'Loading…',
          spinner: true,
        ),
        // Pause the poll while a page scroll is in flight (swipe or tap-driven
        // animate) — a mid-transition rebuild is what stalled the animation.
        RootStatus.granted => Column(
          children: [
            // Standing notice on hardware this build isn't for — updates are
            // disabled there (an sm8850 kernel would brick a different device).
            if (!_deviceSupported) const _UnsupportedDeviceBanner(),
            // Standing warning strip on a foreign (non-Picters) kernel.
            if (!_onPictersKernel) const _KernelWarningBanner(),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n is ScrollStartNotification) {
                    _controller.setPollPaused(true);
                  } else if (n is ScrollEndNotification) {
                    _controller.setPollPaused(false);
                  }
                  return false;
                },
                child: PageView(
            controller: _pageController,
            physics: const _SnappyPagePhysics(),
            onPageChanged: _onPageChanged,
            // Each page in its own layer, so a swipe just translates it
            // instead of repainting both screens every frame. Kept alive so
            // leaving a tab and coming back preserves its state — expanded
            // module groups, the search text and the active filter — instead
            // of rebuilding the screen collapsed from scratch.
            children: [
              _KeepAlive(
                key: const ValueKey('page-overview'),
                child: RepaintBoundary(
                  child: OverviewScreen(controller: _controller),
                ),
              ),
              _KeepAlive(
                key: const ValueKey('page-modules'),
                child: RepaintBoundary(
                  child: ModulesScreen(controller: _controller),
                ),
              ),
              if (!hidePerf)
                _KeepAlive(
                  key: const ValueKey('page-performance'),
                  child: RepaintBoundary(
                    child: PerformanceScreen(controller: _controller.perf),
                  ),
                ),
              _KeepAlive(
                key: const ValueKey('page-settings'),
                child: RepaintBoundary(
                  child: SettingsScreen(controller: _controller.settings),
                ),
              ),
            ],
                ),
              ),
            ),
          ],
        ),
      },
      bottomNavigationBar: granted
          ? RepaintBoundary(
              child: ValueListenableBuilder<int>(
                valueListenable: _tab,
                builder: (context, tab, _) => AppBottomBar(
                  index: tab,
                  onSelect: _goToTab,
                  items: [
                    const BottomBarItem(
                      icon: Icons.home_outlined,
                      selectedIcon: Icons.home,
                      label: 'Overview',
                    ),
                    const BottomBarItem(
                      icon: Icons.tune_outlined,
                      selectedIcon: Icons.tune,
                      label: 'Modules',
                    ),
                    if (!hidePerf)
                      const BottomBarItem(
                        icon: Icons.speed_outlined,
                        selectedIcon: Icons.speed,
                        label: 'Performance',
                      ),
                    const BottomBarItem(
                      icon: Icons.settings_outlined,
                      selectedIcon: Icons.settings,
                      label: 'Settings',
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }
}

/// Wraps a PageView child so it isn't disposed when it scrolls off-screen —
/// the two tabs then keep their state across switches.
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({super.key, required this.child});

  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _RootDenied extends StatelessWidget {
  const _RootDenied({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _content(context),
    );
  }

  Widget _content(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.lock_outline,
                size: 40,
                color: scheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: 24),
            Text('Root required', style: textTheme.headlineSmall),
            const SizedBox(height: 12),
            Text(
              'Grant Superuser access in KernelSU, APatch or Magisk. It ships '
              'as a system app, so turn on "Show system apps" in your manager '
              'to find it in the list. The app unlocks itself once you grant it.',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: () => NativeBridge.restartApp(),
              icon: const Icon(Icons.restart_alt),
              label: const Text('Restart app'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Combined "What's new" for the update dialog: the app's release notes plus the
/// kernel's, if any. Null when there's nothing to show. Drops a leading markdown
/// "What's Changed" heading so it doesn't echo the section title above it.
String? _updateNotes(UpdateInfo? app, KernelUpdateInfo? kern) {
  final parts = <String>[
    if (app != null && app.notes.trim().isNotEmpty) app.notes.trim(),
    if (kern != null && kern.notes.trim().isNotEmpty) kern.notes.trim(),
  ];
  if (parts.isEmpty) return null;
  final text = parts
      .join('\n\n———\n\n')
      .replaceFirst(
          RegExp(r"^#+\s*What.?s Changed\s*", caseSensitive: false), '')
      .trim();
  return text.isEmpty ? null : text;
}

/// One combined update sheet for everything — the app APK and/or the kernel +
/// OOT-modules build. A single Install downloads each (a bar per artifact),
/// installs them (x/y), then prompts a reboot to activate the modules.
void _showUpdateDialog(BuildContext context, UpdateController controller) {
  if (!controller.anyUpdateAvailable) return;

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final textTheme = Theme.of(context).textTheme;
        final phase = controller.updatePhase;
        final busy = controller.combinedUpdateBusy;
        final app = controller.availableUpdate;
        final kern = controller.kernelUpdateAvailable
            ? controller.availableKernelUpdate
            : null;

        final Widget content;
        final List<Widget> actions;

        if (busy) {
          content = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                phase == UpdatePhase.installing
                    ? 'Installing ${controller.installedCount}/${controller.updateTasks.length}…'
                    : 'Downloading…',
                style: textTheme.bodyMedium,
              ),
              const SizedBox(height: 14),
              for (final t in controller.updateTasks)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _TaskProgress(
                    task: t,
                    installing: phase == UpdatePhase.installing,
                  ),
                ),
            ],
          );
          actions = const [];
        } else if (phase == UpdatePhase.error) {
          content = Text(controller.combinedUpdateError ?? 'Update failed.');
          actions = [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: () => controller.installAllUpdates(),
              child: const Text('Retry'),
            ),
          ];
        } else if (controller.rebootPending) {
          // Persisted across app restarts until the actual reboot (boot_id).
          content = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final t in controller.updateTasks)
                _TaskLine(label: t.label, done: t.installed),
              if (controller.updateTasks.isNotEmpty)
                const SizedBox(height: 12),
              Text('Installed. Reboot to activate the kernel modules.',
                  style: textTheme.bodyMedium),
            ],
          );
          actions = [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('Later'),
            ),
            FilledButton.icon(
              onPressed: () => controller.rebootForUpdate(),
              icon: const Icon(Icons.restart_alt, size: 18),
              label: const Text('Reboot'),
            ),
          ];
        } else if (phase == UpdatePhase.done) {
          content = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final t in controller.updateTasks)
                _TaskLine(label: t.label, done: t.installed),
              const SizedBox(height: 12),
              Text('Installed.', style: textTheme.bodyMedium),
            ],
          );
          actions = [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('Done'),
            ),
          ];
        } else {
          content = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('The following will be downloaded and installed:',
                  style: textTheme.bodyMedium),
              const SizedBox(height: 10),
              if (kern != null)
                _TaskLine(label: 'Kernel & modules · ${kern.dateLabel}'),
              if (app != null) _TaskLine(label: 'App · v${app.version}'),
              if (kern != null && controller.abDevice) ...[
                const SizedBox(height: 14),
                Text('Flash kernel to slot',
                    style: textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final s in controller.slots)
                      ChoiceChip(
                        label: Text(
                          '${s == '_a' ? 'A' : 'B'}'
                          '${s == controller.activeSlot ? ' · active' : ''}',
                        ),
                        selected: controller.selectedSlot == s,
                        onSelected: (_) => controller.setSelectedSlot(s),
                      ),
                  ],
                ),
              ],
              // Only a kernel/modules update needs a reboot to activate — an
              // app-only update installs in place, so don't threaten a reboot.
              if (kern != null) ...[
                const SizedBox(height: 12),
                Text(
                  'The device will reboot at the end to activate the kernel '
                  'modules.',
                  style: textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
              if (_updateNotes(app, kern) case final notes?) ...[
                const SizedBox(height: 16),
                Text("What's new", style: textTheme.titleSmall),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: SingleChildScrollView(
                    child: Text(
                      notes,
                      style: textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ),
              ],
            ],
          );
          actions = [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('Later'),
            ),
            FilledButton.icon(
              onPressed: () => controller.installAllUpdates(),
              icon: const Icon(Icons.bolt, size: 18),
              label: const Text('Install'),
            ),
          ];
        }

        return PopScope(
          canPop: !busy,
          child: AlertDialog(
            title: const Text('Updates available'),
            content: SizedBox(width: double.maxFinite, child: content),
            actions: actions,
          ),
        );
      },
    ),
  );
}

/// A labelled row for the update list — a hollow circle by default, a filled
/// check once its artifact is installed.
class _TaskLine extends StatelessWidget {
  const _TaskLine({required this.label, this.done = false});

  final String label;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            done ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 17,
            color: done ? scheme.primary : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

/// A per-artifact progress bar: download percentage while downloading, then an
/// indeterminate bar that fills to a check once the artifact is installed.
class _TaskProgress extends StatelessWidget {
  const _TaskProgress({required this.task, required this.installing});

  final UpdateTask task;
  final bool installing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final done = task.installed;
    final value = installing ? (done ? 1.0 : null) : task.downloadProgress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(task.label,
                  style: Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis),
            ),
            if (done)
              Icon(Icons.check_circle, size: 15, color: scheme.primary)
            else if (!installing && task.downloadProgress != null)
              Text('${(task.downloadProgress! * 100).round()}%',
                  style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: value, minHeight: 6),
        ),
      ],
    );
  }
}

/// An attention-grabbing "Update" chip for the app bar — a filled accent pill
/// that gently pulses (scale + glow) so a pending update is impossible to miss,
/// unlike the plain icon it replaces.
class _UpdatePill extends StatefulWidget {
  const _UpdatePill({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_UpdatePill> createState() => _UpdatePillState();
}

class _UpdatePillState extends State<_UpdatePill>
    with TickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1150),
  )..repeat(reverse: true);

  // One-shot entrance: pops + fades in the first time the pill appears.
  late final AnimationController _entry = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: AnimatedBuilder(
          animation: Listenable.merge([_c, _entry]),
          builder: (context, child) {
            final pulse = Curves.easeInOut.transform(_c.value);
            final entered = Curves.easeOutBack.transform(_entry.value);
            final opacity = Curves.easeOut.transform(_entry.value).clamp(0.0, 1.0);
            final scale = (0.7 + 0.3 * entered) * (1 + 0.04 * pulse);
            return Opacity(
              opacity: opacity,
              child: Transform.scale(scale: scale, child: child),
            );
          },
          child: Material(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () {
                HapticFeedback.selectionClick();
                widget.onTap();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.system_update,
                      size: 17,
                      color: scheme.onPrimary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Update',
                      style: TextStyle(
                        color: scheme.onPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Standing warning shown under the app bar when the running kernel isn't a
/// Picters build — injection and the bundled modules aren't guaranteed there.
class _KernelWarningBanner extends StatelessWidget {
  const _KernelWarningBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 20, color: scheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Not running the Picters kernel — Wi-Fi injection and the '
                  'bundled modules may not work.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.w500,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Standing notice shown under the app bar when the device isn't a Xiaomi 17
/// series phone (sm8850). Updates are hard-disabled there — the kernel and OOT
/// modules are built for that SoC and would brick or fail on anything else.
class _UnsupportedDeviceBanner extends StatelessWidget {
  const _UnsupportedDeviceBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.block, size: 20, color: scheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Unsupported device — updates are disabled. This build is only '
                  'for the Xiaomi 17 series (sm8850).',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.w500,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CenterGlyph extends StatelessWidget {
  const _CenterGlyph({
    required this.icon,
    required this.title,
    this.spinner = false,
  });

  final IconData icon;
  final String title;
  final bool spinner;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (spinner)
            MorphingPolygon(size: 52, color: scheme.primary)
          else
            Icon(icon, color: scheme.onSurfaceVariant, size: 48),
          const SizedBox(height: 20),
          Text(title, style: TextStyle(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
