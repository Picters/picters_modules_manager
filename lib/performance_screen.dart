import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'perf_controller.dart';
import 'device_control_cards.dart';
import 'control_surfaces.dart';
import 'perf_info.dart';
import 'theme.dart';
import 'widgets.dart';

/// CPU/GPU caps and performance governors, with optional boot persistence.
class PerformanceScreen extends StatelessWidget {
  const PerformanceScreen({
    super.key,
    required this.controller,
    this.preview = false,
  });

  final PerfController controller;
  final bool preview;

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
                profile: controller.pendingProfile ?? controller.profile,
                busy: controller.busy,
                applyingProfile: controller.pendingProfile != null,
                state: state,
                onSelect: (p) => _select(context, p),
              )
            else
              const _UpdateModuleNote(),
            const SizedBox(height: 16),
            DeviceControlCards(
              preview: preview,
              persistOnBoot: controller.persistOnBoot,
            ),
            if (state.bootApplySupported) ...[
              const SizedBox(height: 26),
              const SectionHeader(
                icon: Icons.save_outlined,
                label: 'Persistence',
              ),
              const SizedBox(height: 12),
              _PersistCard(
                enabled: controller.persistOnBoot,
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
  PerfProfile.ultraEco => Icons.severe_cold,
  PerfProfile.eco => Icons.ac_unit,
  PerfProfile.balanced => Icons.balance,
  PerfProfile.full => Icons.bolt,
  PerfProfile.gaming => Icons.sports_esports_outlined,
};

/// Frequency readings and profile controls share a single card.
class _ProfileHero extends StatelessWidget {
  const _ProfileHero({
    required this.profile,
    required this.busy,
    required this.applyingProfile,
    required this.state,
    required this.onSelect,
  });

  final PerfProfile profile;
  final bool busy;
  final bool applyingProfile;
  final PerfState state;
  final Future<void> Function(PerfProfile) onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final capped = profile != PerfProfile.full && profile != PerfProfile.gaming;
    bool enabled(PerfProfile p) =>
        !busy && (p != PerfProfile.gaming || state.gamingSupported);

    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const SectionHeader(icon: Icons.memory, label: 'CPU/GPU'),
            const SizedBox(height: 12),
            for (final cluster in state.clusters) ...[
              _FrequencyPlate(
                label: clusterLabel(cluster, state.clusters),
                icon: Icons.developer_board_outlined,
                value: formatCpuFreq(
                  cappedMax(
                    profile,
                    cpuDomain(cluster, state.clusters),
                    cluster.maxHardware,
                    cluster.availableFreqs,
                  ),
                ),
                highlighted: capped,
                gaming: profile == PerfProfile.gaming,
              ),
              const SizedBox(height: 8),
            ],
            if (state.gpu case final gpu?)
              _FrequencyPlate(
                label: 'Adreno GPU',
                icon: Icons.auto_awesome_motion_outlined,
                value: capped
                    ? formatGpuFreq(
                        cappedMax(
                          profile,
                          PerfDomain.gpu,
                          gpu.stockMax,
                          gpu.availableFreqs,
                        ),
                      )
                    : 'Max',
                highlighted: capped,
                gaming: profile == PerfProfile.gaming,
              ),
            const SizedBox(height: 12),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              child: Text(
                '${profile.label} profile',
                key: ValueKey(profile),
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 4),
            _ProfileDescription(profile: profile, busy: applyingProfile),
            const SizedBox(height: 10),
            _ProfileRail(
              profile: profile,
              enabled: enabled,
              onSelect: onSelect,
            ),
            if (!state.kernelCapsSupported) ...[
              const SizedBox(height: 12),
              Text(
                'Update the kernel for frequency caps that hold.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProfileDescription extends StatefulWidget {
  const _ProfileDescription({required this.profile, required this.busy});

  final PerfProfile profile;
  final bool busy;

  @override
  State<_ProfileDescription> createState() => _ProfileDescriptionState();
}

class _ProfileDescriptionState extends State<_ProfileDescription>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 240),
  );
  late final CurvedAnimation _textSize = CurvedAnimation(
    parent: _motion,
    curve: Curves.easeInOutCubic,
  );
  late PerfProfile _displayed = widget.profile;
  Completer<void>? _applied;
  bool _animating = false;

  @override
  void didUpdateWidget(covariant _ProfileDescription oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.busy && _applied != null && !_applied!.isCompleted) {
      _applied!.complete();
    }
    if (!_animating &&
        ((!oldWidget.busy && widget.busy) || widget.profile != _displayed)) {
      _transition();
    }
  }

  Future<void> _transition() async {
    _animating = true;
    _applied = Completer<void>();
    if (!widget.busy) _applied!.complete();
    try {
      await _motion.reverse().orCancel;
      // Keep the loading stage visible even when the operation finishes quickly.
      await Future.wait([
        _applied!.future,
        Future<void>.delayed(const Duration(milliseconds: 160)),
      ]);
      if (!mounted) return;
      setState(() => _displayed = widget.profile);
      await _motion.forward().orCancel;
    } on TickerCanceled {
      // The tab was disposed while transitioning.
    } finally {
      if (mounted) setState(() => _animating = false);
      if (mounted && (widget.busy || widget.profile != _displayed)) {
        _transition();
      }
    }
  }

  @override
  void dispose() {
    if (_applied != null && !_applied!.isCompleted) _applied!.complete();
    _textSize.dispose();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 24,
      child: Stack(
        alignment: Alignment.center,
        children: [
          FadeTransition(
            opacity: ReverseAnimation(_textSize),
            child: ScaleTransition(
              scale: ReverseAnimation(_textSize),
              child: TickerMode(
                enabled: _animating,
                child: MorphingPolygon(size: 17, color: scheme.primary),
              ),
            ),
          ),
          SizeTransition(
            axis: Axis.horizontal,
            sizeFactor: _textSize,
            child: FadeTransition(
              opacity: _textSize,
              child: Text(
                _displayed.blurb,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FrequencyPlate extends StatelessWidget {
  const _FrequencyPlate({
    required this.label,
    required this.icon,
    required this.value,
    required this.highlighted,
    required this.gaming,
  });

  final String label;
  final IconData icon;
  final String value;
  final bool highlighted;
  final bool gaming;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final row = Row(
            children: [
              Icon(icon, size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              const SizedBox(width: 8),
              ReelPill(
                text: value,
                highlight: highlighted,
                accent: gaming ? const Color(0xFFFF8A80) : null,
              ),
            ],
          );
          return constraints.maxWidth < 160
              ? FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SizedBox(width: 160, child: row),
                )
              : row;
        },
      ),
    );
  }
}

class _ProfileRail extends StatelessWidget {
  const _ProfileRail({
    required this.profile,
    required this.enabled,
    required this.onSelect,
  });

  final PerfProfile profile;
  final bool Function(PerfProfile) enabled;
  final Future<void> Function(PerfProfile) onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const profiles = PerfProfile.values;
    return Container(
      key: const ValueKey('performance-profile-picker'),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Corners.chip),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth / profiles.length;
          return SizedBox(
            height: 68,
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  left: profiles.indexOf(profile) * width,
                  top: 0,
                  bottom: 0,
                  width: width,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(Corners.chip - 4),
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (final p in profiles)
                      Expanded(
                        child: Semantics(
                          label: p.label,
                          button: true,
                          enabled: enabled(p),
                          selected: p == profile,
                          child: Tooltip(
                            message: p == PerfProfile.gaming && !enabled(p)
                                ? 'Performance governors unavailable or busy'
                                : p.label,
                            child: JellyTap(
                              onTap: enabled(p) ? () => onSelect(p) : null,
                              child: SizedBox(
                                height: 68,
                                child: Center(
                                  child: Icon(
                                    _profileIcon(p),
                                    size: 30,
                                    color: p == profile
                                        ? scheme.onPrimaryContainer
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PersistCard extends StatelessWidget {
  const _PersistCard({required this.enabled, required this.onChanged});

  final bool enabled;
  final Future<void> Function(bool) onChanged;

  @override
  Widget build(BuildContext context) {
    return Card.outlined(
      child: JellySwitchTile(
        secondary: ControlIcon(Icons.save_outlined, active: enabled),
        title: 'Keep after reboot',
        value: enabled,
        onChanged: onChanged,
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
              child: Icon(
                Icons.system_update_alt,
                color: scheme.primary,
                size: 24,
              ),
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
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
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
                Icon(
                  Icons.speed_outlined,
                  size: 48,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(height: 16),
                Text(
                  'No CPU controls found',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  "This device doesn't expose cpufreq policies, or root hasn't "
                  'been granted yet.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
