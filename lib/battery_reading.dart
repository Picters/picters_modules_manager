/// Read-only battery telemetry. Linux power_supply units: tenths °C, µA, µV.
/// The current sign is normalized using battery status for the captured SM8850
/// driver, which reports positive magnitude even while discharging.
class BatteryReading {
  const BatteryReading({
    this.percent,
    this.temperatureC,
    this.currentMa,
    this.voltageV,
    this.connected = false,
    this.charging = false,
  });

  final int? percent;
  final double? temperatureC;
  final double? currentMa;
  final double? voltageV;
  final bool connected;
  final bool charging;

  /// Power at the battery terminals, not charger-adapter input power.
  double? get batteryWatts => currentMa == null || voltageV == null
      ? null
      : currentMa! / 1000 * voltageV!;

  static BatteryReading? parse(Iterable<String> lines) {
    final fields = <String, String>{};
    for (final line in lines) {
      final separator = line.indexOf('=');
      if (separator > 0) {
        fields[line.substring(0, separator)] = line
            .substring(separator + 1)
            .trim();
      }
    }
    double? number(String key) => double.tryParse(fields[key] ?? '');
    final level = int.tryParse(fields['capacity'] ?? '');
    final rawTemp = number('temp');
    final rawVoltage = number('voltage_now');
    final rawCurrent = number('current_now');
    final status = fields['status'];
    final charging = status == 'Charging';
    final discharging = status == 'Discharging';
    final percent = level != null && level >= 0 && level <= 100 ? level : null;
    final temp =
        rawTemp != null &&
            rawTemp.isFinite &&
            rawTemp >= -400 &&
            rawTemp <= 1000
        ? rawTemp / 10
        : null;
    final volts =
        rawVoltage != null &&
            rawVoltage.isFinite &&
            rawVoltage >= 2e6 &&
            rawVoltage <= 10e6
        ? rawVoltage / 1e6
        : null;
    final current =
        rawCurrent != null &&
            rawCurrent.isFinite &&
            rawCurrent.abs() <= 1e8 &&
            (charging || discharging)
        ? rawCurrent.abs() / 1000 * (charging ? 1 : -1)
        : null;
    if (percent == null && temp == null && current == null && volts == null) {
      return null;
    }
    return BatteryReading(
      percent: percent,
      temperatureC: temp,
      currentMa: current,
      voltageV: volts,
      charging: charging,
      connected:
          charging ||
          status == 'Full' ||
          fields['usb_online'] == '1' ||
          fields['wireless_online'] == '1',
    );
  }
}

const batteryScanFragment = r'''
for pmm_battery_field in status capacity temp voltage_now current_now; do
  pmm_battery_node=/sys/class/power_supply/battery/$pmm_battery_field
  [ -r "$pmm_battery_node" ] || continue
  printf '%s=' "$pmm_battery_field"
  cat "$pmm_battery_node" 2>/dev/null
  printf '\n'
done
for pmm_supply in usb wireless; do
  pmm_supply_node=/sys/class/power_supply/$pmm_supply/online
  [ -r "$pmm_supply_node" ] || continue
  printf '%s_online=' "$pmm_supply"
  cat "$pmm_supply_node" 2>/dev/null
  printf '\n'
done
''';
