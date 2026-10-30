import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/battery_reading.dart';

void main() {
  test('Xiaomi capture normalizes consumption and Linux sensor units', () {
    final reading = BatteryReading.parse([
      'status=Discharging',
      'capacity=83',
      'temp=390',
      'voltage_now=4164000',
      'current_now=1549000',
    ])!;
    expect(reading.temperatureC, 39);
    expect(reading.currentMa, -1549);
    expect(reading.voltageV, 4.164);
    expect(reading.batteryWatts, closeTo(-6.450036, 0.000001));
    expect(reading.connected, isFalse);
  });
  test(
    'charging reports positive battery power, not adapter advertised power',
    () {
      final reading = BatteryReading.parse([
        'status=Charging',
        'temp=365',
        'voltage_now=4200000',
        'current_now=-2000000',
        'usb_online=1',
      ])!;
      expect(reading.currentMa, 2000);
      expect(reading.batteryWatts, closeTo(8.4, 0.001));
      expect(reading.connected, isTrue);
    },
  );
  test('missing or invalid sensors do not become fabricated readings', () {
    expect(BatteryReading.parse([]), isNull);
    expect(
      BatteryReading.parse(['temp=NaN', 'capacity=101', 'voltage_now=0']),
      isNull,
    );
    final connected = BatteryReading.parse([
      'capacity=80',
      'status=Not charging',
      'usb_online=1',
    ])!;
    expect(connected.connected, isTrue);
    expect(connected.batteryWatts, isNull);
  });
}
