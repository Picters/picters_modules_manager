import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'app_bottom_bar.dart';
import 'brand_mark.dart';
import 'module_repository.dart';
import 'modules_screen.dart';
import 'native_bridge.dart';
import 'overview_screen.dart';
import 'performance_screen.dart';
import 'settings_screen.dart';
import 'widgets.dart';
import 'theme.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, this.controller, this.preview = false});
  final AppController? controller;
  final bool preview;
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
  late final AppController _controller;
  final PageController _pageController = PageController();
  final ValueNotifier<int> _tab = ValueNotifier(0);
  StreamSubscription<void>? _usbSub;
  RootStatus _rootStatus = RootStatus.checking;
  bool _settingsReady = false;
  bool _hasUpdate = false;
  bool _onPictersKernel = true;
  bool _deviceSupported = true;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? AppController(ModuleRepository());
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_handleControllerChanged);
    _controller.releases.addListener(_handleControllerChanged);
    _controller.settings.addListener(_handleControllerChanged);
    _controller.init();
    if (!widget.preview) {
      _usbSub = NativeBridge.usbEvents().listen((_) {
        if (_controller.rootStatus == RootStatus.granted) _controller.refresh();
      });
    }
  }

  void _handleControllerChanged() {
    if (!mounted) return;
    final ready = _controller.settings.loaded;
    final status = _controller.rootStatus;
    final update = _controller.releases.newReleaseAvailable;
    final authentic = _controller.onPictersKernel;
    final supported = _controller.releases.deviceSupported;
    if (ready == _settingsReady &&
        status == _rootStatus &&
        update == _hasUpdate &&
        authentic == _onPictersKernel &&
        supported == _deviceSupported) {
      return;
    }
    setState(() {
      _settingsReady = ready;
      _rootStatus = status;
      _hasUpdate = update;
      _onPictersKernel = authentic;
      _deviceSupported = supported;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _usbSub?.cancel();
    _controller.removeListener(_handleControllerChanged);
    _controller.releases.removeListener(_handleControllerChanged);
    _controller.settings.removeListener(_handleControllerChanged);
    _controller.dispose();
    _pageController.dispose();
    _tab.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _controller.setForeground(state == AppLifecycleState.resumed);

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

  /// Brings the nav bar back in line with the page actually on screen.
  ///
  /// A tap moves the chip immediately — it has to feel instant — while the page
  /// flies there over 320ms. Put a finger down during that flight and the
  /// PageView stops and settles wherever it is, which is often the page it
  /// started from; no page index ever changed, so onPageChanged never fires and
  /// the chip is left pointing at a tab that was never reached. Reconciling once
  /// everything has come to rest is what makes the two agree again.
  void _syncTabToPage() {
    if (!_pageController.hasClients) return;
    final page = _pageController.page?.round();
    if (page == null || page == _tab.value) return;
    _tab.value = page;
  }

  bool _handleScroll(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      _controller.setPollPaused(true);
      if (notification.depth == 0 && notification.dragDetails != null) {
        _navGen++;
        _programmaticPage = false;
      }
    } else if (notification is ScrollEndNotification) {
      _controller.setPollPaused(false);
      if (notification.depth == 0) _syncTabToPage();
    }
    return false;
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: SettingsScreen(
                controller: _controller.settings,
                preview: widget.preview,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final granted = _rootStatus == RootStatus.granted && _settingsReady;
    const titles = ['Overview', 'Modules', 'Performance'];
    return Scaffold(
      extendBody: true,
      appBar: AppBar(
        toolbarHeight: 64,
        title: ValueListenableBuilder<int>(
          valueListenable: _tab,
          builder: (context, tab, _) =>
              Text(granted ? titles[tab] : 'Kernel Manager'),
        ),
        actions: [
          if (_hasUpdate) _ReleasePill(onTap: () => _openReleases(context)),
          if (granted)
            _SquareIconButton(
              icon: Icons.settings_outlined,
              tooltip: 'Settings',
              onTap: _openSettings,
            ),
          const SizedBox(width: 20),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: switch (_rootStatus) {
              RootStatus.checking => const _CenterGlyph(
                icon: Icons.hourglass_empty,
                title: 'Checking root access…',
                spinner: true,
              ),
              RootStatus.denied => _RootDenied(controller: _controller),
              RootStatus.granted when !_settingsReady => const _CenterGlyph(
                icon: Icons.hourglass_empty,
                title: 'Loading…',
                spinner: true,
              ),
              RootStatus.granted => Row(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        if (!_deviceSupported) const _UnsupportedDeviceBanner(),
                        if (!_onPictersKernel) const _KernelWarningBanner(),
                        Expanded(
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 960),
                              child: NotificationListener<ScrollNotification>(
                                onNotification: _handleScroll,
                                child: PageView(
                                  controller: _pageController,
                                  physics: const _SnappyPagePhysics(),
                                  onPageChanged: _onPageChanged,
                                  allowImplicitScrolling: true,
                                  children: [
                                    _KeepAlive(
                                      key: const ValueKey('page-overview'),
                                      child: OverviewScreen(
                                        controller: _controller,
                                      ),
                                    ),
                                    _KeepAlive(
                                      key: const ValueKey('page-modules'),
                                      child: ModulesScreen(
                                        controller: _controller,
                                      ),
                                    ),
                                    _KeepAlive(
                                      key: const ValueKey('page-performance'),
                                      child: PerformanceScreen(
                                        controller: _controller.perf,
                                        preview: widget.preview,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            },
          ),
        ],
      ),
      bottomNavigationBar: granted
          ? ValueListenableBuilder<int>(
              valueListenable: _tab,
              builder: (context, index, _) => AppBottomBar(
                index: index,
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
                    icon: Icons.speed_outlined,
                    selectedIcon: Icons.speed,
                    label: 'Performance',
                  ),
                ],
              ),
            )
          : null,
    );
  }
}

/// An app-bar action drawn as a filled rounded square rather than a bare glyph.
///
/// A plain IconButton floats unanchored in the bar and its ripple is a circle
/// that matches nothing else on screen; a tinted tile gives the action an
/// edge to sit against, in the same rounded-square family as the cards below
/// it. JellyTap supplies the press feedback, so there's no Material splash to
/// compete with the squash.
class _SquareIconButton extends StatelessWidget {
  const _SquareIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Tooltip(
        message: tooltip,
        child: Semantics(
          label: tooltip,
          button: true,
          child: JellyTap(
            onTap: onTap,
            child: Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Icon(icon, size: 21, color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      ),
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
            // The mark carries this screen — it's the first thing anyone sees,
            // so it's the app introducing itself, with the lock as a badge on
            // the heading rather than a wall of red.
            const FloatingBrandMark(size: 104),
            const SizedBox(height: 26),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 9),
                Text('Root required', style: textTheme.headlineSmall),
              ],
            ),
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
            Jelly(
              child: FilledButton.icon(
                onPressed: () => NativeBridge.restartApp(),
                icon: const Icon(Icons.restart_alt),
                label: const Text('Restart app'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openReleases(BuildContext context) async {
  final opened = await NativeBridge.openKernelReleases();
  if (!opened && context.mounted) {
    showError(
      context,
      'Could not open GitHub. Open Picters kernel releases in your browser.',
    );
  }
}

/// A GitHub releases chip for the app bar — a filled accent pill
/// that gently pulses when a newer manual release is available,
/// unlike the plain icon it replaces.
class _ReleasePill extends StatefulWidget {
  const _ReleasePill({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_ReleasePill> createState() => _ReleasePillState();
}

class _ReleasePillState extends State<_ReleasePill>
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
            final opacity = Curves.easeOut
                .transform(_entry.value)
                .clamp(0.0, 1.0);
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
              Icon(
                Icons.warning_amber_rounded,
                size: 20,
                color: scheme.onErrorContainer,
              ),
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
                  'Unsupported device. Kernel and modules are built only '
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
