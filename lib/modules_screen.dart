import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'module_categories.dart';
import 'module_info.dart';
import 'theme.dart';
import 'widgets.dart';

class ModulesScreen extends StatelessWidget {
  const ModulesScreen({super.key, required this.controller});

  final AppController controller;

  Future<void> _toggle(BuildContext context, ModuleInfo m, bool v) async {
    final err = await controller.toggleModule(m, v);
    if (!context.mounted) return;
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

        final wifi = state.wifiModules;
        final other = state.otherModules;
        final byCategory = <ModuleCategory, List<ModuleInfo>>{};
        for (final m in other) {
          byCategory.putIfAbsent(categoryOf(m.name), () => []).add(m);
        }

        return RefreshIndicator(
          onRefresh: controller.refresh,
          color: AppColors.white,
          backgroundColor: AppColors.surfaceHigh,
          child: ListView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
            children: [
              const ScreenTitle('Modules', subtitle: 'Deep configuration'),
              _ModuleGroup(
                label: 'Wi-Fi stack',
                hint: 'cfg80211/mac80211 are usually switched from the Overview screen.',
                modules: wifi,
                controller: controller,
                onToggle: (m, v) => _toggle(context, m, v),
              ),
              for (final cat in categoryOrder)
                if (byCategory[cat]?.isNotEmpty ?? false) ...[
                  const SizedBox(height: 22),
                  _ModuleGroup(
                    label: cat.label,
                    modules: byCategory[cat]!,
                    controller: controller,
                    onToggle: (m, v) => _toggle(context, m, v),
                  ),
                ],
            ],
          ),
        );
      },
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
    final on = modules.where((m) => m.loaded).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: sectionLabelStyle),
            const Spacer(),
            Text('$on / ${modules.length}',
                style: const TextStyle(color: AppColors.grayDim, fontSize: 13)),
          ],
        ),
        if (hint != null) ...[
          const SizedBox(height: 4),
          Text(hint!,
              style: const TextStyle(color: AppColors.grayDim, fontSize: 12.5)),
        ],
        const SizedBox(height: 12),
        GlassCard(
          child: Column(
            children: [
              for (var i = 0; i < modules.length; i++) ...[
                if (i > 0) const CardDivider(),
                _ModuleRow(
                  module: modules[i],
                  busy: controller.moduleBusy.contains(modules[i].name),
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
    required this.onChanged,
  });

  final ModuleInfo module;
  final bool busy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              module.name,
              style: TextStyle(
                color: module.loaded ? AppColors.white : AppColors.gray,
                fontSize: 17,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 12),
          if (busy)
            const SizedBox(
              width: 22,
              height: 22,
              child:
                  CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.white),
            )
          else
            Switch(value: module.loaded, onChanged: onChanged),
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
    return RefreshIndicator(
      onRefresh: onRetry,
      color: AppColors.white,
      backgroundColor: AppColors.surfaceHigh,
      child: ListView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        children: [
          const SizedBox(height: 160),
          const Icon(Icons.inventory_2_outlined,
              size: 52, color: AppColors.grayDim),
          const SizedBox(height: 18),
          const Text(
            'No OOT modules found',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: AppColors.white, fontSize: 19, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Install the OOT modules zip from your KernelSU or Magisk '
              'manager first, then reopen the app.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.gray, fontSize: 14, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
