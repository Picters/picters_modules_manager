import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'module_categories.dart';
import 'module_info.dart';
import 'theme.dart';
import 'widgets.dart';

class ModulesScreen extends StatefulWidget {
  const ModulesScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<ModulesScreen> createState() => _ModulesScreenState();
}

class _ModulesScreenState extends State<ModulesScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  AppController get controller => widget.controller;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _toggle(ModuleInfo m, bool v) async {
    HapticFeedback.selectionClick();
    final err = await controller.toggleModule(m, v);
    if (!mounted) return;
    if (err != null) {
      showError(context, err);
      if (controller.lastModuleDiagnostics != null) {
        showDiagnosticsDialog(context, controller.lastModuleDiagnostics!);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final state = controller.state;

        if (!state.modulesDirExists || state.modules.isEmpty) {
          return _EmptyModules(onRetry: controller.refresh);
        }

        return RefreshIndicator(
          onRefresh: controller.refresh,
          child: ListView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
            children: [
              _SearchField(
                controller: _search,
                onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
              ),
              const SizedBox(height: 16),
              if (_query.isNotEmpty)
                ..._buildSearchResults(context, state)
              else
                ..._buildGrouped(context, state),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _buildSearchResults(BuildContext context, SystemState state) {
    final matches = state.modules
        .where((m) => m.name.toLowerCase().contains(_query))
        .toList();
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
        label: 'Results',
        modules: matches,
        controller: controller,
        onToggle: _toggle,
      ),
    ];
  }

  List<Widget> _buildGrouped(BuildContext context, SystemState state) {
    final wifi = state.wifiModules;
    final other = state.otherModules;
    final byCategory = <ModuleCategory, List<ModuleInfo>>{};
    for (final m in other) {
      byCategory.putIfAbsent(categoryOf(m.name), () => []).add(m);
    }

    return [
      _ModuleGroup(
        label: 'Wi-Fi stack',
        hint: 'cfg80211/mac80211 are usually switched from the Overview screen.',
        modules: wifi,
        controller: controller,
        onToggle: _toggle,
      ),
      for (final cat in categoryOrder)
        if (byCategory[cat]?.isNotEmpty ?? false) ...[
          const SizedBox(height: 20),
          _ModuleGroup(
            label: cat.label,
            modules: byCategory[cat]!,
            controller: controller,
            onToggle: _toggle,
          ),
        ],
    ];
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
          borderRadius: BorderRadius.circular(28),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _ModuleGroup extends StatelessWidget {
  const _ModuleGroup({
    required this.label,
    required this.modules,
    required this.controller,
    required this.onToggle,
    this.hint,
  });

  final String label;
  final String? hint;
  final List<ModuleInfo> modules;
  final AppController controller;
  final void Function(ModuleInfo, bool) onToggle;

  @override
  Widget build(BuildContext context) {
    if (modules.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final on = modules.where((m) => m.loaded).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(label: label, trailing: '$on / ${modules.length}'),
        if (hint != null) ...[
          const SizedBox(height: 6),
          Text(
            hint!,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 10),
        Card.outlined(
          child: Column(
            children: [
              for (var i = 0; i < modules.length; i++) ...[
                if (i > 0) const CardDivider(),
                _ModuleRow(
                  module: modules[i],
                  busy: controller.moduleBusy.contains(modules[i].name),
                  optimisticLoaded: controller.optimisticModuleLoaded[modules[i].name],
                  onChanged: (v) => onToggle(modules[i], v),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ModuleRow extends StatelessWidget {
  const _ModuleRow({
    required this.module,
    required this.busy,
    required this.optimisticLoaded,
    required this.onChanged,
  });

  final ModuleInfo module;
  final bool busy;
  final bool? optimisticLoaded;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
      trailing: busy
          ? const SizedBox(
              width: 40,
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          : Switch(value: loaded, onChanged: onChanged),
    );
  }
}

class _EmptyModules extends StatelessWidget {
  const _EmptyModules({required this.onRetry});
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: onRetry,
      child: ListView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
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
                    'Install the OOT modules zip from your KernelSU or Magisk '
                    'manager first, then reopen the app.',
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
      ),
    );
  }
}
