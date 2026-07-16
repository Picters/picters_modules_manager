import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app_controller.dart';
import 'module_repository.dart';
import 'modules_screen.dart';
import 'native_bridge.dart';
import 'overview_screen.dart';
import 'theme.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final AppController _controller = AppController(ModuleRepository());
  int _tab = 0;

  static const _titles = ['Overview', 'Modules'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controller.setForeground(state == AppLifecycleState.resumed);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final granted = _controller.rootStatus == RootStatus.granted;
        return Scaffold(
          appBar: AppBar(
            title: Text(granted ? _titles[_tab] : 'Kernel Manager'),
            actions: [
              if (_controller.availableUpdate != null)
                IconButton(
                  icon: const Icon(Icons.system_update),
                  tooltip: 'Update available',
                  onPressed: () => _showUpdateDialog(context, _controller),
                ),
              _OverflowMenu(controller: _controller),
            ],
          ),
          body: switch (_controller.rootStatus) {
            RootStatus.checking => const _CenterGlyph(
                icon: Icons.hourglass_empty,
                title: 'Checking root access…',
                spinner: true,
              ),
            RootStatus.denied => _RootDenied(controller: _controller),
            RootStatus.granted => AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                switchInCurve: Curves.easeOutCubic,
                child: _tab == 0
                    ? OverviewScreen(
                        key: const ValueKey('overview'),
                        controller: _controller,
                      )
                    : ModulesScreen(
                        key: const ValueKey('modules'),
                        controller: _controller,
                      ),
              ),
          },
          bottomNavigationBar: granted
              ? NavigationBar(
                  selectedIndex: _tab,
                  onDestinationSelected: (i) => setState(() => _tab = i),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.shield_moon_outlined),
                      selectedIcon: Icon(Icons.shield_moon),
                      label: 'Overview',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.tune_outlined),
                      selectedIcon: Icon(Icons.tune),
                      label: 'Modules',
                    ),
                  ],
                )
              : null,
        );
      },
    );
  }
}

/// The app-bar "⋮" menu: pin a home-screen shortcut, jump to the root manager,
/// and an About sheet. These used to be documented features with no UI wired
/// to them — now they live here.
class _OverflowMenu extends StatelessWidget {
  const _OverflowMenu({required this.controller});

  final AppController controller;

  Future<void> _pinShortcut(BuildContext context) async {
    final ok = await NativeBridge.requestPinShortcut();
    if (!context.mounted) return;
    if (ok) {
      showInfo(context, 'Shortcut request sent to your launcher.');
    } else {
      showError(context, "Your launcher doesn't support pinned shortcuts.");
    }
  }

  Future<void> _openRootManager(BuildContext context) async {
    final ok = await NativeBridge.openRootManager();
    if (!context.mounted) return;
    if (!ok) {
      showError(context, 'No KernelSU / APatch / Magisk manager found.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      onSelected: (value) {
        switch (value) {
          case 'pin':
            _pinShortcut(context);
          case 'root':
            _openRootManager(context);
          case 'about':
            showAboutSheet(context);
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: 'pin',
          child: ListTile(
            leading: Icon(Icons.add_to_home_screen_outlined),
            title: Text('Pin shortcut'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'root',
          child: ListTile(
            leading: Icon(Icons.admin_panel_settings_outlined),
            title: Text('Open root manager'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'about',
          child: ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('About'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}

Future<void> showAboutSheet(BuildContext context) async {
  final info = await PackageInfo.fromPlatform();
  if (!context.mounted) return;
  final scheme = Theme.of(context).colorScheme;
  final textTheme = Theme.of(context).textTheme;
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(Icons.shield_moon, color: scheme.onPrimaryContainer),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Picters Kernel Manager',
                          style: textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text('Version ${info.version} (${info.buildNumber})',
                          style: textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              'Controls the out-of-tree NetHunter Wi-Fi injection stack and the '
              'other OOT kernel drivers over root — everything unloaded by default. '
              'Use Overview to switch the whole Wi-Fi stack; use Modules for '
              'per-driver control.',
              style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    ),
  );
}

class _RootDenied extends StatelessWidget {
  const _RootDenied({required this.controller});

  final AppController controller;

  Future<void> _openRootManager(BuildContext context) async {
    final ok = await NativeBridge.openRootManager();
    if (!context.mounted) return;
    if (!ok) {
      showError(context, 'No KernelSU / APatch / Magisk manager found.');
    }
  }

  @override
  Widget build(BuildContext context) {
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
              child: Icon(Icons.lock_outline, size: 40, color: scheme.onErrorContainer),
            ),
            const SizedBox(height: 24),
            Text('Root required', style: textTheme.headlineSmall),
            const SizedBox(height: 12),
            Text(
              'Grant Superuser access to Picters Kernel Manager in your '
              'KernelSU, APatch or Magisk manager, then come back — the app '
              'unlocks on its own.',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: () => _openRootManager(context),
              icon: const Icon(Icons.admin_panel_settings_outlined),
              label: const Text('Open root manager'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
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
      showInfo(context, 'Update installed — reopen the app to use v${update.version}.');
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
            const CircularProgressIndicator(strokeWidth: 2.5)
          else
            Icon(icon, color: scheme.onSurfaceVariant, size: 48),
          const SizedBox(height: 18),
          Text(title, style: TextStyle(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
