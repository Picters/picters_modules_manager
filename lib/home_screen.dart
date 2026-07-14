import 'package:flutter/material.dart';

import 'module_info.dart';
import 'module_repository.dart';
import 'native_bridge.dart';
import 'root_shell.dart';
import 'usb_devices.dart';

enum _LoadState { loading, rootUnavailable, ready }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ModuleRepository _repo = ModuleRepository();
  final UsbScanner _usb = UsbScanner();

  _LoadState _state = _LoadState.loading;
  ScanResult _scan = const ScanResult(
    modules: [],
    vendorWifiLoaded: true,
    modulesDirExists: false,
  );
  List<DetectedAdapter> _detected = const [];
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    setState(() => _state = _LoadState.loading);
    final hasRoot = await RootShell.checkRoot();
    if (!hasRoot) {
      if (!mounted) return;
      setState(() => _state = _LoadState.rootUnavailable);
      return;
    }
    await _refresh();
  }

  Future<void> _refresh() async {
    final results = await Future.wait([_repo.scan(), _usb.scan()]);
    if (!mounted) return;
    setState(() {
      _scan = results[0] as ScanResult;
      _detected = results[1] as List<DetectedAdapter>;
      _state = _LoadState.ready;
    });
  }

  ModuleInfo? _findModule(String name) {
    for (final m in _scan.modules) {
      if (m.name == name) return m;
    }
    return null;
  }

  Future<void> _toggleModule(ModuleInfo module, bool wantOn) async {
    setState(() => _busy.add(module.name));

    ShellResult result;
    try {
      result = await _repo.setLoaded(module, wantOn, _scan.modules);
    } on ModulePrecondition catch (e) {
      if (!mounted) return;
      setState(() => _busy.remove(module.name));
      _showError(e.message);
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy.remove(module.name));
      _showError('${wantOn ? 'Load' : 'Unload'} failed: $e');
      return;
    }

    final isRestoreAttempt = !wantOn && module.name == 'cfg80211';
    final restoreOk = isRestoreAttempt ? _repo.restoreSucceeded(result) : null;

    final results = await Future.wait([_repo.scan(), _usb.scan()]);
    if (!mounted) return;
    final rescanned = results[0] as ScanResult;
    final updated = rescanned.modules.firstWhere(
      (m) => m.name == module.name,
      orElse: () => module,
    );
    setState(() {
      _scan = rescanned;
      _detected = results[1] as List<DetectedAdapter>;
      _busy.remove(module.name);
    });

    if (isRestoreAttempt) {
      if (restoreOk == true) {
        _showInfo('Stock Wi-Fi restored.');
      } else {
        _showError('Could not restore stock Wi-Fi automatically — reboot to restore it.');
      }
      return;
    }

    if (updated.loaded != wantOn) {
      _showError(
        '${wantOn ? 'Failed to load' : 'Failed to unload'} ${module.name}: '
        '${result.errorSummary}',
      );
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showInfo(String message) {
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: scheme.primaryContainer,
      ));
  }

  Future<void> _openRootManager() async {
    final opened = await NativeBridge.openRootManager();
    if (!mounted) return;
    if (opened != null) {
      _showInfo('Opened $opened — grant root there, then come back and retry.');
    } else {
      _showError(
        "Couldn't find a known manager app automatically — open yours "
        'manually (Superuser tab) and grant root to Picters Modules Manager.',
      );
    }
  }

  Future<void> _pinShortcut() async {
    final ok = await NativeBridge.requestPinShortcut();
    if (!mounted) return;
    if (ok) {
      _showInfo('Check your home screen to confirm the shortcut.');
    } else {
      _showError("Your launcher doesn't support adding shortcuts this way.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Picters Modules Manager'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_to_home_screen),
            tooltip: 'Add to home screen',
            onPressed: _pinShortcut,
          ),
          if (_state == _LoadState.ready)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Rescan',
              onPressed: _refresh,
            ),
        ],
      ),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (_state) {
      case _LoadState.loading:
        return const Center(child: CircularProgressIndicator());
      case _LoadState.rootUnavailable:
        return _RootUnavailableView(onRetry: _init, onOpenManager: _openRootManager);
      case _LoadState.ready:
        if (!_scan.modulesDirExists || _scan.modules.isEmpty) {
          return _EmptyModulesView(onRetry: _refresh);
        }
        return _ReadyView(
          scan: _scan,
          detected: _detected,
          busy: _busy,
          onToggle: _toggleModule,
          onRefresh: _refresh,
          findModule: _findModule,
        );
    }
  }
}

class _ReadyView extends StatelessWidget {
  const _ReadyView({
    required this.scan,
    required this.detected,
    required this.busy,
    required this.onToggle,
    required this.onRefresh,
    required this.findModule,
  });

  final ScanResult scan;
  final List<DetectedAdapter> detected;
  final Set<String> busy;
  final void Function(ModuleInfo module, bool wantOn) onToggle;
  final Future<void> Function() onRefresh;
  final ModuleInfo? Function(String name) findModule;

  @override
  Widget build(BuildContext context) {
    final wifiModules = scan.modules.where((m) => m.isWifiClass).toList();
    final otherModules = scan.modules.where((m) => !m.isWifiClass).toList();

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24, top: 8),
        children: [
          if (!scan.vendorWifiLoaded) _InjectionModeBanner(theme: Theme.of(context)),
          _DetectedAdaptersBlock(
            detected: detected,
            busy: busy,
            findModule: findModule,
            onLoad: (m) => onToggle(m, true),
          ),
          _ModuleBlock(
            title: 'Wi-Fi injection',
            icon: Icons.wifi,
            modules: wifiModules,
            busy: busy,
            onToggle: onToggle,
          ),
          _ModuleBlock(
            title: 'Other drivers',
            icon: Icons.memory,
            modules: otherModules,
            busy: busy,
            onToggle: onToggle,
          ),
        ],
      ),
    );
  }
}

/// A real visual block: one tonal, rounded Card per category, not just a text
/// header floating over a flat list.
class _ModuleBlock extends StatelessWidget {
  const _ModuleBlock({
    required this.title,
    required this.icon,
    required this.modules,
    required this.busy,
    required this.onToggle,
  });

  final String title;
  final IconData icon;
  final List<ModuleInfo> modules;
  final Set<String> busy;
  final void Function(ModuleInfo module, bool wantOn) onToggle;

  @override
  Widget build(BuildContext context) {
    if (modules.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                Icon(icon, size: 20, color: scheme.primary),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '${modules.where((m) => m.loaded).length}/${modules.length} on',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          for (final module in modules)
            _ModuleTile(
              module: module,
              busy: busy.contains(module.name),
              onChanged: (v) => onToggle(module, v),
            ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _ModuleTile extends StatelessWidget {
  const _ModuleTile({
    required this.module,
    required this.busy,
    required this.onChanged,
  });

  final ModuleInfo module;
  final bool busy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      title: Text(module.name),
      subtitle: Text(module.loaded ? 'Loaded' : 'Not loaded'),
      leading: Icon(
        module.loaded ? Icons.check_circle : Icons.circle_outlined,
        color: module.loaded ? scheme.primary : scheme.outline,
        size: 20,
      ),
      trailing: busy
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          : Switch(value: module.loaded, onChanged: onChanged),
    );
  }
}

class _DetectedAdaptersBlock extends StatelessWidget {
  const _DetectedAdaptersBlock({
    required this.detected,
    required this.busy,
    required this.findModule,
    required this.onLoad,
  });

  final List<DetectedAdapter> detected;
  final Set<String> busy;
  final ModuleInfo? Function(String name) findModule;
  final void Function(ModuleInfo module) onLoad;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final recognized = detected.where((d) => d.recognized).toList();
    final unknownCount = detected.length - recognized.length;

    return Card(
      elevation: 0,
      color: scheme.tertiaryContainer.withValues(alpha: 0.35),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                Icon(Icons.usb, size: 20, color: scheme.primary),
                const SizedBox(width: 10),
                Text(
                  'Plugged-in adapters',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (recognized.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Text(
                unknownCount > 0
                    ? 'No recognized Wi-Fi adapter plugged in ($unknownCount other USB device${unknownCount == 1 ? '' : 's'} seen).'
                    : 'No USB adapter plugged in.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            )
          else ...[
            for (final d in recognized) _DetectedAdapterTile(
              detected: d,
              module: findModule(d.match!.driver),
              busy: busy.contains(d.match!.driver),
              onLoad: onLoad,
            ),
            if (unknownCount > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  '+ $unknownCount other USB device${unknownCount == 1 ? '' : 's'} not recognized as a Wi-Fi adapter.',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
          ],
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _DetectedAdapterTile extends StatelessWidget {
  const _DetectedAdapterTile({
    required this.detected,
    required this.module,
    required this.busy,
    required this.onLoad,
  });

  final DetectedAdapter detected;
  final ModuleInfo? module;
  final bool busy;
  final void Function(ModuleInfo module) onLoad;

  @override
  Widget build(BuildContext context) {
    final match = detected.match!;
    final m = module;

    Widget trailing;
    if (busy) {
      trailing = const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      );
    } else if (m == null) {
      trailing = const Text('not staged');
    } else if (m.loaded) {
      trailing = const Icon(Icons.check_circle, color: Colors.green);
    } else {
      trailing = FilledButton.tonal(
        onPressed: () => onLoad(m),
        child: const Text('Load'),
      );
    }

    return ListTile(
      dense: true,
      leading: const Icon(Icons.wifi_tethering),
      title: Text(detected.device.displayName),
      subtitle: Text('${detected.device.idPair} · needs ${match.driver}'),
      trailing: trailing,
    );
  }
}

class _InjectionModeBanner extends StatelessWidget {
  const _InjectionModeBanner({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: scheme.onTertiaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Injection mode is active. Turn cfg80211 off below to try restoring '
              'stock Wi-Fi, or reboot if that doesn\'t bring it back.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _RootUnavailableView extends StatelessWidget {
  const _RootUnavailableView({required this.onRetry, required this.onOpenManager});
  final VoidCallback onRetry;
  final VoidCallback onOpenManager;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 48, color: scheme.error),
            const SizedBox(height: 16),
            Text(
              'Root access unavailable',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'This app needs root once, like any KernelSU/Magisk app: open your '
              'manager\'s Superuser tab and grant it to Picters Modules Manager. '
              'After that it won\'t ask again.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onOpenManager,
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open root manager'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyModulesView extends StatelessWidget {
  const _EmptyModulesView({required this.onRetry});
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inventory_2_outlined, size: 48, color: scheme.outline),
            const SizedBox(height: 16),
            Text(
              'No OOT modules found',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Install the Picters NetHunter OOT modules zip from your '
              'KernelSU or Magisk manager first, then reopen this app.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Rescan'),
            ),
          ],
        ),
      ),
    );
  }
}
