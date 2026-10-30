import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'device_controls.dart';
import 'control_slider_shapes.dart';
import 'control_surfaces.dart';
import 'widgets.dart';

/// The UI can be tried on desktop; device writes require a verified backend.
class ThermalControlCard extends StatefulWidget {
  const ThermalControlCard({
    super.key,
    this.preview = false,
    this.persistOnBoot = false,
    this.controller,
  });
  final bool preview;
  final bool persistOnBoot;
  final DeviceControlsController? controller;

  @override
  State<ThermalControlCard> createState() => _ThermalControlCardState();
}

class _ThermalControlCardState extends State<ThermalControlCard> {
  late final DeviceControlsController _controls =
      widget.controller ?? DeviceControlsController(preview: widget.preview);

  @override
  void initState() {
    super.initState();
    _controls.setBootPersistence(widget.persistOnBoot);
  }

  @override
  void didUpdateWidget(covariant ThermalControlCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.persistOnBoot != widget.persistOnBoot) {
      _controls.setBootPersistence(widget.persistOnBoot);
    }
  }

  double? _drag;
  bool? _pendingEnabled;
  // Forty one-degree steps, followed by a separate magnetic Off endpoint.
  static const _normalEnd = 40 / 45;

  double _snap(double value) =>
      value > 42.5 / 45 ? 1.0 : ((value * 45).round().clamp(0, 40) / 45);
  static const _red = Color(0xFFFF8A80);

  bool get _enabled =>
      _pendingEnabled ?? (_controls.thermalPreset != ThermalPreset.stock);

  Future<void> _toggle(bool value) async {
    if (_pendingEnabled != null || _controls.busy) return;
    HapticFeedback.selectionClick();
    setState(() => _pendingEnabled = value);
    try {
      if (value) {
        await _controls.setThermalPreset(ThermalPreset.custom);
      } else {
        await _controls.restoreThermalStock();
      }
    } finally {
      if (mounted) setState(() => _pendingEnabled = null);
    }
  }

  Future<void> _applySlider(double value) async {
    if (_controls.busy || _pendingEnabled != null) return;
    final snapped = _snap(value);
    setState(() => _drag = snapped);
    try {
      if (snapped > 0.96) {
        await _controls.setThermalLimitDisabled(true);
      } else {
        await _controls.setCustomTemp(
          (25 + (snapped / _normalEnd).clamp(0, 1) * 40).roundToDouble(),
        );
      }
    } finally {
      // Keep the chosen target visible throughout application; the controller
      // commits on success and retains the old profile on failure.
      if (mounted) setState(() => _drag = null);
    }
  }

  @override
  void dispose() {
    if (widget.controller == null) _controls.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _controls,
      builder: (context, _) {
        final value =
            _drag ??
            (_controls.thermalLimitDisabled
                ? 1.0
                : (_controls.customTemp - 25) / 40 * _normalEnd);
        final unlimited = value > 0.96;
        final temperature = (25 + (value / _normalEnd).clamp(0, 1) * 40)
            .round();
        final color = Color.lerp(
          scheme.primary,
          _red,
          ((temperature - 25) / 40).clamp(0.0, 1.0),
        )!;
        final available = _controls.thermalSupported && !_controls.busy;
        return Card.outlined(
          clipBehavior: Clip.antiAlias,
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
                    Icons.thermostat_outlined,
                    active: _enabled,
                  ),
                  title: const ControlRowTitle('Custom throttling'),
                  subtitle: widget.preview || _controls.thermalSupported
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
                                const Expanded(child: Text('Battery')),
                                Text(
                                  unlimited ? 'Off' : '$temperature °C',
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
                                trackShape: const LimitSliderTrack(),
                                tickMarkShape: SliderTickMarkShape.noTickMark,
                                thumbShape: LimitSliderHandle(
                                  hidden: unlimited,
                                ),
                                overlayShape: unlimited
                                    ? SliderComponentShape.noOverlay
                                    : null,
                                showValueIndicator: ShowValueIndicator.onDrag,
                              ),
                              child: Stack(
                                alignment: Alignment.centerRight,
                                children: [
                                  IgnorePointer(
                                    child: Padding(
                                      padding: EdgeInsets.zero,
                                      child: Container(
                                        key: const ValueKey(
                                          'thermal-off-endpoint',
                                        ),
                                        width: 24,
                                        height: 24,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: unlimited
                                              ? _red
                                              : scheme.surfaceContainerHighest,
                                          border: Border.all(
                                            color: unlimited
                                                ? _red
                                                : scheme.outlineVariant,
                                          ),
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
                                  ),
                                  Slider(
                                    key: const ValueKey(
                                      'thermal-battery-slider',
                                    ),
                                    value: value,
                                    divisions: 45,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    label: unlimited
                                        ? 'Off'
                                        : '$temperature °C',
                                    semanticFormatterCallback: (v) => v > 0.96
                                        ? 'Custom thermal limit off'
                                        : '${(25 + (v / _normalEnd).clamp(0, 1) * 40).round()} degrees Celsius',
                                    onChanged: available
                                        ? (v) {
                                            final next = _snap(v);
                                            if (next != value) {
                                              HapticFeedback.selectionClick();
                                              setState(() => _drag = next);
                                            }
                                          }
                                        : null,
                                    onChangeEnd: available
                                        ? _applySlider
                                        : null,
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
                                    flex: 40,
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          '25 °C',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.labelSmall,
                                        ),
                                        Text(
                                          '65 °C',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.labelSmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Spacer(flex: 5),
                                ],
                              ),
                            ),
                            AnimatedSize(
                              duration: const Duration(milliseconds: 220),
                              child: unlimited || temperature >= 55
                                  ? Padding(
                                      padding: const EdgeInsets.only(top: 12),
                                      child: Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: _red.withValues(alpha: 0.10),
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                        ),
                                        child: Text(
                                          'Not recommended without a cooler. High temperatures may damage the device.',
                                          textAlign: TextAlign.center,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(color: _red),
                                        ),
                                      ),
                                    )
                                  : const SizedBox(width: double.infinity),
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
