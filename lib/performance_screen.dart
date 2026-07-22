import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'perf_controller.dart';
import 'perf_info.dart';
import 'theme.dart';
import 'widgets.dart';

/// The Performance tab: pick a CPU/GPU frequency-cap profile (Cool / Balanced /
/// Full). Caps only ever snap to real OPP steps and never exceed stock, so it's
/// safe by construction. Persisting is applied by the module at boot, so if a
/// setting ever misbehaves, removing the module reverts everything to stock.
class PerformanceScreen extends StatelessWidget {
  const PerformanceScreen({super.key, required this.controller});

  final PerfController controller;

  Future<void> _select(BuildContext context, PerfProfile p) async {
    if (p == controller.profile) return;
    HapticFeedback.selectionClick();
    await controller.setProfile(p);
    if (!context.mounted) return;
    if (controller.lastError != null) {
      showError(context, controller.lastError!);
    } else {
      showInfo(context, '${p.label} profile applied.');
    }
  }

  Future<void> _setPersist(BuildContext context, bool v) async {
    HapticFeedback.selectionClick();
    await controller.setPersistOnBoot(v);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.supported) {
          return _Unsupported(onRetry: controller.refresh);
        }
        final state = controller.state;
        return PolygonScrollView(
          onRefresh: controller.refresh,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
          children: [
            if (state.bootApplySupported)
              _ProfileHero(
                profile: controller.profile,
                busy: controller.busy,
                onSelect: (p) => _select(context, p),
              )
            else
              const _UpdateModuleNote(),
            const SizedBox(height: 26),
            const SectionHeader(icon: Icons.memory, label: 'CPU'),
            const SizedBox(height: 12),
            Card.outlined(
              child: Column(
                children: [
                  for (var i = 0; i < state.clusters.length; i++) ...[
                    if (i > 0) const CardDivider(),
                    _ClusterRow(
                      cluster: state.clusters[i],
                      label: clusterLabel(state.clusters[i], state.clusters),
                      profile: controller.profile,
                    ),
                  ],
                ],
              ),
            ),
            if (state.gpu != null) ...[
              const SizedBox(height: 26),
              const SectionHeader(
                  icon: Icons.videogame_asset_outlined, label: 'GPU'),
              const SizedBox(height: 12),
              Card.outlined(
                  child: _GpuRow(gpu: state.gpu!, profile: controller.profile)),
            ],
            if (state.bootApplySupported) ...[
              const SizedBox(height: 26),
              const SectionHeader(icon: Icons.save_outlined, label: 'Persistence'),
              const SizedBox(height: 12),
              _PersistCard(
                enabled: controller.persistOnBoot,
                busy: controller.busy,
                onChanged: (v) => _setPersist(context, v),
              ),
            ],
          ],
        );
      },
    );
  }
}

IconData _profileIcon(PerfProfile p) => switch (p) {
      PerfProfile.cool => Icons.ac_unit,
      PerfProfile.balanced => Icons.balance,
      PerfProfile.full => Icons.bolt,
    };

/// The hero card: the active profile's icon + blurb, and the three-way profile
/// selector underneath.
class _ProfileHero extends StatelessWidget {
  const _ProfileHero({
    required this.profile,
    required this.busy,
    required this.onSelect,
  });

  final PerfProfile profile;
  final bool busy;
  final ValueChanged<PerfProfile> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final capped = profile != PerfProfile.full;
    return RepaintBoundary(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 340),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: capped
              ? Color.alphaBlend(
                  scheme.primary.withValues(alpha: 0.09),
                  scheme.surfaceContainerHigh,
                )
              : scheme.surfaceContainerHigh,
          border: Border.all(
            color: capped
                ? scheme.primary.withValues(alpha: 0.45)
                : Colors.transparent,
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(Corners.hero),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 54,
                  height: 54,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: capped
                        ? scheme.primary
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(
                    _profileIcon(profile),
                    color: capped ? scheme.onPrimary : scheme.onSurfaceVariant,
                    size: 27,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              '${profile.label} profile',
                              style: textTheme.titleMedium?.copyWith(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w700,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (busy) ...[
                            const SizedBox(width: 10),
                            MorphingPolygon(size: 17, color: scheme.primary),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        profile.blurb,
                        style: textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            IgnorePointer(
              ignoring: busy,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                opacity: busy ? 0.5 : 1.0,
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<PerfProfile>(
                    segments: [
                      for (final p in PerfProfile.values)
                        ButtonSegment(
                          value: p,
                          label: Text(p.label),
                        ),
                    ],
                    selected: {profile},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) => onSelect(s.first),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One CPU cluster row: its label, core count + stock ceiling, and the current
/// max-frequency cap (accented when it's below stock).
class _ClusterRow extends StatelessWidget {
  const _ClusterRow({
    required this.cluster,
    required this.label,
    required this.profile,
  });

  final CpuCluster cluster;
  final String label;
  final PerfProfile profile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Show the cap this profile sets — not the live scaling_max_freq, which the
    // vendor perf daemon (perfd) constantly rewrites, so it would flicker and
    // read wrong at Full.
    final cap = cappedMax(profile, cluster.maxHardware, cluster.availableFreqs);
    final capped = profile != PerfProfile.full;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: scheme.surfaceContainerHighest,
        child: Icon(Icons.developer_board,
            color: scheme.onSurfaceVariant, size: 20),
      ),
      title: Text(label),
      subtitle: Text(
        '${cluster.coreCount} cores · up to ${formatCpuFreq(cluster.maxHardware)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: _FreqTablet(text: formatCpuFreq(cap), capped: capped),
    );
  }
}

class _GpuRow extends StatelessWidget {
  const _GpuRow({required this.gpu, required this.profile});

  final GpuInfo gpu;
  final PerfProfile profile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cap = cappedMax(profile, gpu.stockMax, gpu.availableFreqs);
    final capped = profile != PerfProfile.full;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: scheme.surfaceContainerHighest,
        child: Icon(Icons.auto_awesome_motion_outlined,
            color: scheme.onSurfaceVariant, size: 20),
      ),
      title: const Text('Adreno GPU'),
      subtitle: Text(
        'up to ${formatGpuFreq(gpu.stockMax)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: _FreqTablet(text: formatGpuFreq(cap), capped: capped),
    );
  }
}

class _FreqTablet extends StatelessWidget {
  const _FreqTablet({required this.text, required this.capped});

  final String text;
  final bool capped;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
      decoration: BoxDecoration(
        color: capped ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: capped ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
      ),
    );
  }
}

class _PersistCard extends StatelessWidget {
  const _PersistCard({
    required this.enabled,
    required this.busy,
    required this.onChanged,
  });

  final bool enabled;
  final bool busy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card.outlined(
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        secondary: busy
            ? SizedBox(
                width: 24,
                height: 24,
                child: MorphingPolygon(size: 24, color: scheme.primary),
              )
            : Icon(Icons.save_outlined, color: scheme.onSurfaceVariant),
        title: const Text('Keep after reboot'),
        subtitle: const Text('The module re-applies the profile at boot.'),
        value: enabled,
        onChanged: busy ? null : onChanged,
      ),
    );
  }
}

/// Shown instead of the profile selector when the installed module lacks the
/// perf re-apply loop: without it a cap can't be held (the vendor perf HAL
/// overrides it), so the controls are blocked until the kernel & module are
/// updated.
class _UpdateModuleNote extends StatelessWidget {
  const _UpdateModuleNote();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Icon(Icons.system_update_alt,
                  color: scheme.primary, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Update the module',
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Performance profiles need the latest kernel & module to '
                    'hold. Flash the newest build to enable them.',
                    style: textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Unsupported extends StatelessWidget {
  const _Unsupported({required this.onRetry});
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
                Icon(Icons.speed_outlined, size: 48, color: scheme.onSurfaceVariant),
                const SizedBox(height: 16),
                Text('No CPU controls found',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  "This device doesn't expose cpufreq policies, or root hasn't "
                  'been granted yet.',
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
