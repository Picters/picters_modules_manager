import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'module_repository.dart';
import 'modules_screen.dart';
import 'native_bridge.dart';
import 'overview_screen.dart';
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
  int _tab = 0;

  // Only the fields the shell chrome needs, so the 1s poll doesn't rebuild
  // the whole Scaffold — the two screens have their own AnimatedBuilders.
  RootStatus _rootStatus = RootStatus.checking;
  bool _hasUpdate = false;

  static const _titles = ['Overview', 'Modules'];

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
    _controller.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    final hasUpdate = _controller.availableUpdate != null;
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
  int _pageAnimGen = 0;

  void _goToTab(int i) {
    if (i == _tab) return;
    HapticFeedback.selectionClick();
    final gen = ++_pageAnimGen;
    _programmaticPage = true;
    setState(() => _tab = i);
    _pageController
        .animateToPage(
          i,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        )
        // Only the latest animation clears the flag, so a stale one can't
        // re-arm the swipe haptic early.
        .then((_) {
          if (gen == _pageAnimGen) _programmaticPage = false;
        });
  }

  void _onPageChanged(int i) {
    if (i == _tab) return;
    // A finger-swipe (not a nav-bar tap) gets its own haptic tick.
    if (!_programmaticPage) HapticFeedback.selectionClick();
    setState(() => _tab = i);
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
      appBar: AppBar(
        title: Text(granted ? _titles[_tab] : 'Modules Manager'),
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
            // instead of repainting both screens every frame.
            children: [
              RepaintBoundary(child: OverviewScreen(controller: _controller)),
              RepaintBoundary(child: ModulesScreen(controller: _controller)),
            ],
          ),
        ),
      },
      bottomNavigationBar: granted
          ? RepaintBoundary(
              child: NavigationBar(
                selectedIndex: _tab,
                onDestinationSelected: _goToTab,
                labelBehavior:
                    NavigationDestinationLabelBehavior.onlyShowSelected,
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home),
                    label: 'Overview',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.tune_outlined),
                    selectedIcon: Icon(Icons.tune),
                    label: 'Modules',
                  ),
                ],
              ),
            )
          : null,
    );
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

void _showUpdateDialog(BuildContext context, AppController controller) {
  final update = controller.availableUpdate;
  if (update == null) return;

  Future<void> install() async {
    final err = await controller.downloadAndInstallUpdate();
    if (!context.mounted) return;
    if (err != null) {
      showError(context, err);
    } else {
      Navigator.of(context).pop();
      showInfo(
        context,
        'Update installed — reopen the app to use v${update.version}.',
      );
    }
  }

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final busy = controller.updateBusy;
        final progress = controller.updateProgress;
        return PopScope(
          canPop: !busy,
          child: AlertDialog(
            title: Text('Update available — v${update.version}'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (update.notes.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: SingleChildScrollView(child: Text(update.notes)),
                  ),
                if (busy) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 8),
                  Text(
                    progress == null
                        ? 'Downloading…'
                        : 'Downloading… ${(progress * 100).round()}%',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.of(context).pop(),
                child: const Text('Later'),
              ),
              FilledButton(
                onPressed: busy ? null : install,
                child: Text(busy ? 'Installing…' : 'Update'),
              ),
            ],
          ),
        );
      },
    ),
  );
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
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1150),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, child) {
            final t = Curves.easeInOut.transform(_c.value);
            return Transform.scale(scale: 1 + 0.04 * t, child: child);
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
