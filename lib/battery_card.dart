import 'package:flutter/material.dart';

import 'battery_reading.dart';

/// Battery-terminal telemetry; watts do not represent adapter input power.
class BatteryCard extends StatelessWidget {
  const BatteryCard({super.key, required this.reading});
  final BatteryReading? reading;

  @override
  Widget build(BuildContext context) {
    final value = reading;
    final scheme = Theme.of(context).colorScheme;
    final current = value?.currentMa;
    final watts = value?.batteryWatts;
    final status = value == null
        ? 'Unavailable'
        : value.charging
        ? 'Charging'
        : value.connected
        ? 'Connected'
        : 'Discharging';
    return Semantics(
      container: true,
      label: 'Battery',
      child: Card.outlined(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          child: IntrinsicHeight(
            child: Row(
              children: [
                Icon(
                  value?.charging == true
                      ? Icons.battery_charging_full_rounded
                      : Icons.battery_std_rounded,
                  color: scheme.primary,
                  size: 30,
                ),
                const SizedBox(width: 8),
                Text(
                  value?.percent == null ? '—' : '${value!.percent}%',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 14),
                VerticalDivider(width: 1, color: scheme.outlineVariant),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _Metric(
                              icon: Icons.thermostat_rounded,
                              text: value?.temperatureC == null
                                  ? '— °C'
                                  : '${value!.temperatureC!.toStringAsFixed(1)} °C',
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _Metric(icon: Icons.bolt, text: status),
                          ),
                        ],
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 10),
                        child: Divider(height: 1),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: _Metric(
                              icon: Icons.waves_rounded,
                              text: current == null
                                  ? '— mA'
                                  : '${current > 0 ? '+' : ''}${current.round()} mA',
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Tooltip(
                              message: 'Charging power at the battery',
                              child: _Metric(
                                icon: Icons.bolt,
                                text: value?.charging != true || watts == null
                                    ? '— W'
                                    : '${watts.abs().toStringAsFixed(1)} W',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 5),
        Text(text, style: Theme.of(context).textTheme.labelMedium),
      ],
    ),
  );
}
