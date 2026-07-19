import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_bottom_bar.dart';
import 'app_controller.dart';
import 'module_repository.dart';
import 'modules_screen.dart';
import 'native_bridge.dart';
import 'overview_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';
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
  final PageController _pageController = PageController();

  // Only the fields the shell chrome needs, so the 1s poll doesn't rebuild
  // the whole Scaffold — the two screens have their own AnimatedBuilders.
  RootStatus _rootStatus = RootStatus.checking;
  bool _hasUpdate = false;

  // The active tab as a notifier, NOT setState: only the AppBar title and the
  // nav bar listen to it, so switching tabs never rebuilds the PageView or the
  // two heavy screens. (Doing that mid-swipe was the freeze-then-jump.)
  final ValueNotifier<int> _tab = ValueNotifier(0);

  static const _titles = ['Overview', 'Modules', 'Settings'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_handleControllerChanged);
    _controller.init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_handleControllerChanged);
    _pageController.dispose();
    _tab.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    final hasUpdate = _controller.anyUpdateAvailable;
    if (_controller.rootStatus != _rootStatus || hasUpdate != _hasUpdate) {
      setState(() {
        _rootStatus = _controller.rootStatus;
        _hasUpdate = hasUpdate;
      });
    }
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
    final granted = _rootStatus == RootStatus.granted;
    return Scaffold(
      // The floating bar hovers over the content instead of reserving a strip.
      extendBody: true,
      appBar: AppBar(
        title: granted
            ? ValueListenableBuilder<int>(
                valueListenable: _tab,
                builder: (context, tab, _) => Text(_titles[tab]),
              )
            : const Text('Modules Manager'),
        actions: [
          if (_hasUpdate)
            _UpdatePill(onTap: () => _showUpdateDialog(context, _controller)),
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
        // Pause the poll while a page scroll is in flight (swipe or tap-driven
        // animate) — a mid-transition rebuild is what stalled the animation.
        RootStatus.granted => NotificationListener<ScrollNotification>(
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
                child: RepaintBoundary(
                  child: OverviewScreen(controller: _controller),
                ),
              ),
              _KeepAlive(
                child: RepaintBoundary(
                  child: ModulesScreen(controller: _controller),
                ),
              ),
              _KeepAlive(
                child: RepaintBoundary(
                  child: SettingsScreen(controller: _controller),
                ),
              ),
            ],
          ),
        ),
      },
      bottomNavigationBar: granted
          ? RepaintBoundary(
              child: ValueListenableBuilder<int>(
                valueListenable: _tab,
                builder: (context, tab, _) => AppBottomBar(
                  index: tab,
                  onSelect: _goToTab,
                  items: const [
                    BottomBarItem(
                      icon: Icons.home_outlined,
                      selectedIcon: Icons.home,
                      label: 'Overview',
                    ),
                    BottomBarItem(
                      icon: Icons.tune_outlined,
                      selectedIcon: Icons.tune,
                      label: 'Modules',
                    ),
                    BottomBarItem(
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
  const _KeepAlive({required this.child});

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
    final rechecking = controller.recheckingRoot;
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
              'Grant Superuser access in KernelSU, APatch or Magisk. '
              'The app unlocks itself once you do.',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: rechecking ? null : controller.recheckRoot,
              icon: rechecking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(rechecking ? 'Checking…' : 'Check again'),
            ),
          ],
        ),
      ),
    );
  }
}

/// One combined update sheet for everything — the app APK and/or the kernel +
/// OOT-modules build. A single Install downloads each (a bar per artifact),
/// installs them (x/y), then prompts a reboot to activate the modules.
void _showUpdateDialog(BuildContext context, AppController controller) {
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
              const SizedBox(height: 12),
              Text(
                'The device will reboot at the end to activate the kernel '
                'modules.',
                style: textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
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
