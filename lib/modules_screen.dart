import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'module_categories.dart';
import 'module_info.dart';
import 'theme.dart';
import 'widgets.dart';

/// Modules hidden from the per-driver list:
/// - cfg80211/mac80211 are the Wi-Fi core, switched from the Overview screen's
///   Stock/Inject toggle (never module-by-module), so showing them here would
///   let two places fight over the same state.
/// - crc-itu-t / eeprom_93cx6 are dependency-only helper libraries (shipped just
///   so rt73usb / rtl8187 resolve their selected symbols); they auto-load as
///   deps and aren't standalone drivers, so a toggle row for them only confuses.
const Set<String> _hiddenModules = {
  'cfg80211',
  'mac80211',
  'crc-itu-t',
  'eeprom_93cx6',
};

/// Load-state filter for the Modules list.
enum _LoadFilter { all, loaded, unloaded }

class ModulesScreen extends StatefulWidget {
  const ModulesScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<ModulesScreen> createState() => _ModulesScreenState();
}

class _ModulesScreenState extends State<ModulesScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  _LoadFilter _filter = _LoadFilter.all;

  AppController get controller => widget.controller;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _toggle(ModuleInfo m, bool want) async {
    HapticFeedback.selectionClick();
    if (want) {
      // rndis_host needs our cdc_ether (the boot one hides the symbols it uses),
      // so enabling it swaps cdc_ether in — warn, then run the dedicated path.
      if (m.name == 'rndis_host') {
        final ok = await confirmAction(
          context,
          title: 'Enable RNDIS host?',
          message:
              'This swaps the stock cdc_ether for the bundled one so rndis_host '
              'can load, briefly bouncing any USB-Ethernet driver. Unplug USB '
              'Ethernet adapters first.',
          confirmLabel: 'Enable',
        );
        if (!ok || !mounted) return;
        await controller.enableRndisHost(m);
        return;
      }
      // insmod doesn't pull in dependencies and there's no modules.dep for
      // modprobe on this device, so loading e.g. rtl8192cu on its own dies with
      // "Unknown symbol rtl_usb_probe". Resolve what it needs and offer to
      // enable those in place instead of surfacing a cryptic kernel error.
      final plan = controller.planFor(m);
      if (plan.needsInjectMode) {
        showError(
            context, 'Enable Inject mode on the Overview screen first.');
        return;
      }
      if (plan.hasMissingDeps) {
        final ok =
            await showDependencyDialog(context, module: m.name, deps: plan.toLoad);
        if (ok != true || !mounted) return;
        await controller.loadModuleWithDeps(m, plan.toLoad);
        return;
      }
      await controller.toggleModule(m, true);
    } else {
      // Unloading a shared module (e.g. rtlwifi) fails while its users are still
      // up; offer to unload them first instead of a bare "Module is in use".
      final dependents = controller.loadedDependentsOf(m);
      if (dependents.isNotEmpty) {
        final ok = await showDependentsDialog(context,
            module: m.name, dependents: dependents);
        if (ok != true || !mounted) return;
        await controller.unloadModuleWithDependents(m, dependents);
        return;
      }
      await controller.toggleModule(m, false);
    }
  }

  /// Opens the dmesg for a failed module — fetched on demand here, not during
  /// the toggle, so a failure never stalls the next toggle.
  Future<void> _showModuleError(ModuleInfo m) async {
    HapticFeedback.lightImpact();
    final message = controller.moduleErrors[m.name];
    final dmesg = await controller.fetchModuleDmesg(m);
    if (!mounted) return;
    final parts = <String>[
      ?message,
      if (dmesg.isNotEmpty) dmesg,
    ];
    showDiagnosticsDialog(context, parts.join('\n\n'));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final state = controller.state;
        final modules =
            state.modules.where((m) => !_hiddenModules.contains(m.name)).toList();

        if (!state.modulesDirExists || modules.isEmpty) {
          return _EmptyModules(onRetry: controller.refresh);
        }

        final visible = modules.where((m) => switch (_filter) {
              _LoadFilter.all => true,
              _LoadFilter.loaded => m.loaded,
              _LoadFilter.unloaded => !m.loaded,
            }).toList();

        return PolygonScrollView(
          onRefresh: controller.refresh,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
          children: [
            _SearchField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            ),
            const SizedBox(height: 12),
            _FilterBar(
              filter: _filter,
              onChanged: (f) => setState(() => _filter = f),
            ),
            const SizedBox(height: 16),
            if (visible.isEmpty)
              _FilterEmpty(filter: _filter)
            else if (_query.isNotEmpty)
              ..._buildSearchResults(context, visible)
            else
              ..._buildGrouped(context, visible),
          ],
        );
      },
    );
  }

  List<Widget> _buildSearchResults(BuildContext context, List<ModuleInfo> modules) {
    final matches =
        modules.where((m) => m.name.toLowerCase().contains(_query)).toList();
    if (matches.isEmpty) {
      return [
        const SizedBox(height: 40),
        Center(
          child: Text(
            'No module matches "$_query".',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      ];
    }
    return [
      _ModuleGroup(
        key: const ValueKey('mg-results'),
        label: 'Results',
        icon: Icons.search,
        modules: matches,
        controller: controller,
        onToggle: _toggle,
        onShowError: _showModuleError,
        initiallyExpanded: true,
      ),
    ];
  }

  List<Widget> _buildGrouped(BuildContext context, List<ModuleInfo> modules) {
    final wifi = modules.where((m) => m.isWifiClass).toList();
    final other = modules.where((m) => !m.isWifiClass).toList();
    final byCategory = <ModuleCategory, List<ModuleInfo>>{};
    for (final m in other) {
      byCategory.putIfAbsent(categoryOf(m.name), () => []).add(m);
    }

    final groups = <Widget>[
      if (wifi.isNotEmpty)
        _ModuleGroup(
          key: const ValueKey('mg-wifi'),
          label: 'Wi-Fi adapters',
          icon: Icons.wifi_tethering,
          modules: wifi,
          controller: controller,
          onToggle: _toggle,
          onShowError: _showModuleError,
        ),
      for (final cat in categoryOrder)
        if (byCategory[cat]?.isNotEmpty ?? false)
          _ModuleGroup(
            key: ValueKey('mg-${cat.name}'),
            label: cat.label,
            icon: _categoryIcon(cat),
            modules: byCategory[cat]!,
            controller: controller,
            onToggle: _toggle,
            onShowError: _showModuleError,
          ),
    ];

    return [
      for (var i = 0; i < groups.length; i++) ...[
        if (i > 0) const SizedBox(height: 12),
        groups[i],
      ],
    ];
  }
}

/// The All / Loaded / Unloaded segmented filter above the module list. Reuses
/// the app's themed SegmentedButton so it matches the Overview Wi-Fi toggle.
class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.filter, required this.onChanged});

  final _LoadFilter filter;
  final ValueChanged<_LoadFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<_LoadFilter>(
        segments: const [
          ButtonSegment(value: _LoadFilter.all, label: Text('All')),
          ButtonSegment(value: _LoadFilter.loaded, label: Text('Loaded')),
          ButtonSegment(value: _LoadFilter.unloaded, label: Text('Unloaded')),
        ],
        selected: {filter},
        showSelectedIcon: false,
        onSelectionChanged: (s) {
          HapticFeedback.selectionClick();
          onChanged(s.first);
        },
      ),
    );
  }
}

/// Shown when the active filter leaves nothing to list.
class _FilterEmpty extends StatelessWidget {
  const _FilterEmpty({required this.filter});

  final _LoadFilter filter;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final message = switch (filter) {
      _LoadFilter.loaded => 'No modules are loaded right now.',
      _LoadFilter.unloaded => 'Every module is currently loaded.',
      _LoadFilter.all => 'No modules.',
    };
    return Padding(
      padding: const EdgeInsets.only(top: 48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.filter_list_off, size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(message, style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Search modules',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: ValueListenableBuilder(
          valueListenable: controller,
          builder: (context, value, _) => value.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
        ),
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        contentPadding: EdgeInsets.zero,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Corners.field),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

/// A tap-to-expand group of modules: the header shows the category, a loaded
/// count and (if any module in it errored) an error dot; tapping it smoothly
/// unfolds the per-module switches. Custom (not ExpansionTile) so the open/close
/// glides on an eased size+fade instead of the stock abrupt reveal.
class _ModuleGroup extends StatefulWidget {
  const _ModuleGroup({
    super.key,
    required this.label,
    required this.icon,
    required this.modules,
    required this.controller,
    required this.onToggle,
    required this.onShowError,
    this.initiallyExpanded = false,
  });

  final String label;
  final IconData icon;
  final List<ModuleInfo> modules;
  final AppController controller;
  final void Function(ModuleInfo, bool) onToggle;
  final void Function(ModuleInfo) onShowError;
  final bool initiallyExpanded;

  @override
  State<_ModuleGroup> createState() => _ModuleGroupState();
}

class _ModuleGroupState extends State<_ModuleGroup> {
  late bool _expanded = widget.initiallyExpanded;

  void _toggle() {
    HapticFeedback.selectionClick();
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final modules = widget.modules;
    if (modules.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final controller = widget.controller;
    final total = modules.length;
    final on = modules.where((m) => m.loaded).length;
    final hasError =
        modules.any((m) => controller.moduleErrors.containsKey(m.name));
    final active = on > 0;

    return RepaintBoundary(child: Card.outlined(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          JellyTap(
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              child: Row(
                children: [
                  // Leading category icon — anchors the block and fills the
                  // left space so the header reads as a real, substantial row.
                  Container(
                    width: 46,
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active
                          ? scheme.primaryContainer
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Icon(
                      widget.icon,
                      size: 23,
                      color: active
                          ? scheme.onPrimaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.label,
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          active ? '$on of $total loaded' : '$total available',
                          style: textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (hasError) ...[
                    Icon(Icons.error_outline, color: scheme.error, size: 20),
                    const SizedBox(width: 10),
                  ],
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    child: Icon(Icons.expand_more, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity, height: 0),
            secondChild: Column(
              children: [
                const CardDivider(),
                for (var i = 0; i < modules.length; i++) ...[
                  if (i > 0) const CardDivider(),
                  _ModuleRow(
                    module: modules[i],
                    busy: controller.moduleBusy.contains(modules[i].name),
                    hasError: controller.moduleErrors.containsKey(modules[i].name),
                    optimisticLoaded: controller.optimisticModuleLoaded[modules[i].name],
                    onChanged: (v) => widget.onToggle(modules[i], v),
                    onShowError: () => widget.onShowError(modules[i]),
                  ),
                ],
                const SizedBox(height: 4),
              ],
            ),
            crossFadeState:
                _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 240),
            sizeCurve: Curves.easeOutCubic,
            firstCurve: Curves.easeOut,
            secondCurve: Curves.easeOut,
          ),
        ],
      ),
    ));
  }
}

/// A representative icon per module group, so each expander header carries a
/// recognisable glyph instead of empty space.
IconData _categoryIcon(ModuleCategory cat) => switch (cat) {
      ModuleCategory.bluetooth => Icons.bluetooth,
      ModuleCategory.can => Icons.directions_car_filled_outlined,
      ModuleCategory.sdr => Icons.settings_input_antenna,
      ModuleCategory.usbSerial => Icons.cable,
      ModuleCategory.usbEthernet => Icons.lan_outlined,
      ModuleCategory.netfilter => Icons.shield_outlined,
      ModuleCategory.filesystem => Icons.folder_outlined,
      ModuleCategory.other => Icons.extension_outlined,
    };

class _ModuleRow extends StatelessWidget {
  const _ModuleRow({
    required this.module,
    required this.busy,
    required this.hasError,
    required this.optimisticLoaded,
    required this.onChanged,
    required this.onShowError,
  });

  final ModuleInfo module;
  final bool busy;
  final bool hasError;
  final bool? optimisticLoaded;
  final ValueChanged<bool> onChanged;
  final VoidCallback onShowError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The switch shows the optimistic value and flips the instant it's tapped
    // (never replaced by a spinner, so toggling stays snappy). While the root
    // round-trip is in flight the morphing-polygon loader sits just left of the
    // switch; if the toggle failed, a tappable error icon takes that spot and
    // opens the dmesg on tap.
    final loaded = optimisticLoaded ?? module.loaded;
    final desc = moduleDescription(module.name);

    return ListTile(
      title: Text(
        module.name,
        style: TextStyle(
          fontWeight: FontWeight.w500,
          fontFamily: 'monospace',
          color: scheme.onSurface,
        ),
      ),
      subtitle: desc == null ? null : Text(desc),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) ...[
            MorphingPolygon(size: 18, color: scheme.primary),
            const SizedBox(width: 12),
          ] else if (hasError) ...[
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 20,
              color: scheme.error,
              icon: const Icon(Icons.error_outline),
              tooltip: 'Show error',
              onPressed: onShowError,
            ),
            const SizedBox(width: 4),
          ],
          Switch(value: loaded, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _EmptyModules extends StatelessWidget {
  const _EmptyModules({required this.onRetry});
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PolygonScrollView(
      onRefresh: onRetry,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
      children: [
        const SizedBox(height: 100),
        Card.outlined(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Column(
              children: [
                Icon(Icons.inventory_2_outlined, size: 48, color: scheme.onSurfaceVariant),
                const SizedBox(height: 16),
                Text(
                  'No OOT modules found',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Install the OOT modules zip in KernelSU or Magisk, then '
                  'reopen the app.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
