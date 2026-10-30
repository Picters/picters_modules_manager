import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'control_slider_shapes.dart';
import 'control_surfaces.dart';
import 'device_controls.dart';
import 'widgets.dart';

/// Development UI; production writes require the captured charger interfaces.
class ChargingPowerCard extends StatefulWidget {
  const ChargingPowerCard({
    super.key,
    this.preview = false,
    this.persistOnBoot = false,
    this.controller,
  });
  final bool preview;
  final bool persistOnBoot;
  final DeviceControlsController? controller;

  @override
  State<ChargingPowerCard> createState() => _ChargingPowerCardState();
}

class _ChargingPowerCardState extends State<ChargingPowerCard> {
  late final _controls =
      widget.controller ?? DeviceControlsController(preview: widget.preview);
  double? _drag;
  bool? _pendingEnabled;
  static const _normalEnd = 119 / 134;
  static const _red = Color(0xFFFF8A80);
  bool get _enabled => _pendingEnabled ?? _controls.chargingEnabled;
  double _snap(double value) =>
      value > 126.5 / 134 ? 1 : (value * 134).round().clamp(0, 119) / 134;

  @override
  void initState() {
    super.initState();
    _controls.setBootPersistence(widget.persistOnBoot);
  }

  @override
  void didUpdateWidget(covariant ChargingPowerCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.persistOnBoot != widget.persistOnBoot) {
      _controls.setBootPersistence(widget.persistOnBoot);
    }
  }

  Future<void> _toggle(bool value) async {
    if (_controls.busy || _pendingEnabled != null) return;
    HapticFeedback.selectionClick();
    setState(() => _pendingEnabled = value);
    try {
      await _controls.setPowerControlEnabled(value);
    } finally {
      if (mounted) setState(() => _pendingEnabled = null);
    }
  }

  Future<void> _apply(double value) async {
    if (_controls.busy || _pendingEnabled != null) return;
    final selected = _snap(value);
    setState(() => _drag = selected);
    try {
      if (selected == 1) {
        await _controls.clearInputLimit();
      } else {
        await _controls.setInputLimit((1 + selected * 134).roundToDouble());
      }
    } finally {
      if (mounted) setState(() => _drag = null);
    }
  }

  @override
  void dispose() {
    if (widget.controller == null) _controls.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controls,
    builder: (context, _) {
      final scheme = Theme.of(context).colorScheme;
      final value =
          _drag ??
          (_controls.inputLimitDisabled
              ? 1.0
              : (_controls.inputLimit - 1) / 134);
      final unlimited = value == 1;
      final watts = (1 + (value / _normalEnd).clamp(0, 1) * 119).round();
      final color = Color.lerp(scheme.primary, _red, (watts - 1) / 119)!;
      final available =
          _controls.inputLimitSupported &&
          _controls.powerControlAllowed &&
          !_controls.busy;
      return AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: _controls.inputLimitSupported && _controls.powerControlAllowed
            ? 1
            : 0.38,
        child: Card.outlined(
          child: Column(
            children: [
              Jelly(
                enabled: available,
                pressScale: 0.978,
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  minTileHeight: 56,
                  minVerticalPadding: 0,
                  onTap: available ? () => _toggle(!_enabled) : null,
                  leading: ControlIcon(
                    Icons.bolt_rounded,
                    active: _enabled && available,
                  ),
                  title: const ControlRowTitle('Charging power'),
                  subtitle: widget.preview || _controls.inputLimitSupported
                      ? null
                      : const Text('Device profile not verified.'),
                  trailing: JellySwitch(
                    value: _enabled,
                    onChanged: available ? _toggle : null,
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeInOutCubic,
                alignment: Alignment.topCenter,
                child: !_enabled
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                const Expanded(child: Text('Power target')),
                                Text(
                                  unlimited ? 'Off' : '$watts W',
                                  style: TextStyle(
                                    color: color,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                activeTrackColor: color,
                                thumbColor: color,
                                overlayColor: color.withValues(alpha: 0.12),
                                trackShape: const LimitSliderTrack(
                                  normalEnd: _normalEnd,
                                ),
                                thumbShape: LimitSliderHandle(
                                  hidden: unlimited,
                                ),
                                tickMarkShape: SliderTickMarkShape.noTickMark,
                                overlayShape: unlimited
                                    ? SliderComponentShape.noOverlay
                                    : null,
                                showValueIndicator: ShowValueIndicator.onDrag,
                              ),
                              child: Stack(
                                alignment: Alignment.centerRight,
                                children: [
                                  IgnorePointer(
                                    child: Container(
                                      width: 24,
                                      height: 24,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: unlimited
                                            ? _red
                                            : scheme.surfaceContainerHighest,
                                      ),
                                      child: Icon(
                                        Icons.clear_rounded,
                                        size: 16,
                                        color: unlimited
                                            ? const Color(0xFF3B0905)
                                            : scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                  Slider(
                                    key: const ValueKey(
                                      'charging-power-slider',
                                    ),
                                    value: value,
                                    divisions: 134,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    label: unlimited ? 'Off' : '$watts W',
                                    semanticFormatterCallback: (v) => v == 1
                                        ? 'App power limit off'
                                        : '${(1 + v * 134).round()} watts',
                                    onChanged: !available
                                        ? null
                                        : (v) {
                                            final next = _snap(v);
                                            if (next == value) return;
                                            HapticFeedback.selectionClick();
                                            setState(() => _drag = next);
                                          },
                                    onChangeEnd: available ? _apply : null,
                                  ),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    flex: 119,
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: const [
                                        Text('1 W'),
                                        Text('120 W'),
                                      ],
                                    ),
                                  ),
                                  const Spacer(flex: 15),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(
                                unlimited || watts >= 100
                                    ? 'Not recommended without a cooler. High temperatures may damage the device.'
                                    : 'Selected power is a limit, not a guaranteed charging rate.',
                                textAlign: TextAlign.center,
                                style: Theme.of(
                                  context,
                                ).textTheme.bodySmall?.copyWith(color: color),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
