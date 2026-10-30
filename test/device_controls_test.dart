import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/device_controls.dart';

class _DelayedRepository extends DemoDeviceControlsRepository {
  final entered = Completer<void>();
  final release = Completer<void>();
  int applies = 0;

  @override
  Future<DeviceControlsState> apply(DeviceControlSettings settings) async {
    if (applies++ == 0) {
      entered.complete();
      await release.future;
    }
    return super.apply(settings);
  }
}

void main() {
  test('latest boot choice survives an in-flight thermal write', () async {
    final repository = _DelayedRepository();
    final controls = DeviceControlsController(repository: repository);
    addTearDown(controls.dispose);
    final profile = controls.setCustomTemp(58);
    await repository.entered.future;
    final first = controls.setBootPersistence(true);
    final second = controls.setBootPersistence(false);
    final latest = controls.setBootPersistence(true);
    repository.release.complete();
    expect(await profile, isTrue);
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(await latest, isTrue);
    expect(controls.customTemp, 58);
    expect(controls.state.settings.persistOnBoot, isTrue);
    expect(repository.applies, 2);
  });

  test(
    'production is unavailable with no fabricated device readings',
    () async {
      final controls = DeviceControlsController();
      addTearDown(controls.dispose);
      await controls.init();
      expect(controls.preview, isFalse);
      expect(controls.supported, isFalse);
      expect(controls.battery, isNull);
      expect(controls.adapter, isNull);
      expect(
        controls.availabilityMessage,
        contains('Device verification pending'),
      );
      expect(await controls.setThermalPreset(ThermalPreset.gaming), isFalse);
      expect(await controls.setChargingEnabled(true), isFalse);
      expect(await controls.setBypassRequested(true), isFalse);
      expect(await controls.setInputLimit(65), isFalse);
      expect(await controls.setChargeLimit(80), isFalse);
      expect(await controls.restoreThermalStock(), isFalse);
      expect(await controls.restoreChargingStock(), isFalse);
      expect(await controls.restoreStock(), isFalse);
      expect(controls.thermalPreset, ThermalPreset.stock);
      expect(controls.bypassRequested, isFalse);
      expect(controls.chargingEnabled, isFalse);
    },
  );

  test('production repository rejects application even outside controller', () {
    final repository = UnverifiedDeviceControlsRepository();
    expect(
      repository.apply(const DeviceControlSettings(bypassRequested: true)),
      throwsUnsupportedError,
    );
  });

  test(
    'preview supports thermal presets and custom target independently',
    () async {
      final controls = DeviceControlsController(preview: true);
      addTearDown(controls.dispose);
      await controls.init();
      expect(controls.preview, isTrue);
      expect(controls.thermalSupported, isTrue);
      expect(controls.availabilityMessage, contains('Preview only'));
      for (final preset in ThermalPreset.values) {
        expect(await controls.setThermalPreset(preset), isTrue);
        expect(controls.thermalPreset, preset);
      }
      expect(await controls.setCustomTemp(47), isTrue);
      expect(controls.thermalPreset, ThermalPreset.custom);
      expect(controls.customTemp, 47);
      expect(controls.battery!.temperatureC, 36.8);
    },
  );

  test(
    'restore resets every demo selection and keeps demo telemetry',
    () async {
      final controls = DeviceControlsController(preview: true);
      addTearDown(controls.dispose);
      await controls.setCustomTemp(48);
      await controls.setBypassRequested(true);
      await controls.setThermalLimitDisabled(true);
      await controls.setInputLimit(65);
      await controls.setChargeLimit(80);
      expect(controls.bypassRequested, isTrue);
      expect(controls.inputLimit, 65);
      expect(controls.chargeLimit, 80);
      expect(await controls.restoreStock(), isTrue);
      expect(controls.thermalPreset, ThermalPreset.stock);
      expect(controls.customTemp, 45);
      expect(controls.bypassRequested, isFalse);
      expect(controls.inputLimit, 100);
      expect(controls.chargeLimit, 100);
      expect(controls.adapter!.powerW, 27);
      await controls.refresh();
      expect(controls.thermalPreset, ThermalPreset.stock);
    },
  );

  test(
    'thermal reset clears power control and preserves the charge ceiling',
    () async {
      final controls = DeviceControlsController(preview: true);
      addTearDown(controls.dispose);
      await controls.setCustomTemp(48);
      await controls.setThermalLimitDisabled(true);
      await controls.setChargingEnabled(true);
      await controls.setBypassRequested(true);
      await controls.setThermalLimitDisabled(true);
      await controls.setInputLimit(65);
      await controls.setChargeLimit(80);

      expect(await controls.restoreThermalStock(), isTrue);
      await controls.refresh();
      expect(controls.thermalPreset, ThermalPreset.stock);
      expect(controls.customTemp, 45);
      expect(controls.bypassRequested, isTrue);
      expect(controls.chargingEnabled, isFalse);
      expect(controls.inputLimit, 100);
      expect(controls.chargeLimit, 80);
    },
  );

  test('charging reset preserves every thermal selection', () async {
    final controls = DeviceControlsController(preview: true);
    addTearDown(controls.dispose);
    await controls.setCustomTemp(48);
    await controls.setBypassRequested(true);
    await controls.setThermalLimitDisabled(true);
    await controls.setInputLimit(65);
    await controls.setChargeLimit(80);

    expect(await controls.restoreChargingStock(), isTrue);
    await controls.refresh();
    expect(controls.thermalPreset, ThermalPreset.custom);
    expect(controls.customTemp, 48);
    expect(controls.bypassRequested, isFalse);
    expect(controls.inputLimit, 100);
    expect(controls.chargeLimit, 100);
  });

  test(
    'disabling charging restores charging stock and preserves thermal',
    () async {
      final controls = DeviceControlsController(preview: true);
      addTearDown(controls.dispose);
      expect(controls.chargingEnabled, isFalse);
      await controls.setCustomTemp(48);
      await controls.setThermalLimitDisabled(true);
      expect(await controls.setChargingEnabled(true), isTrue);
      expect(controls.chargingEnabled, isTrue);
      await controls.setBypassRequested(true);
      await controls.setThermalLimitDisabled(true);
      await controls.setInputLimit(65);
      await controls.setChargeLimit(80);

      expect(await controls.setChargingEnabled(false), isTrue);
      await controls.refresh();
      expect(controls.chargingEnabled, isFalse);
      expect(controls.bypassRequested, isFalse);
      expect(controls.inputLimit, 100);
      expect(controls.chargeLimit, 100);
      expect(controls.thermalPreset, ThermalPreset.custom);
      expect(controls.customTemp, 48);
    },
  );

  test('power range and Off restore leave thermal settings intact', () async {
    final controls = DeviceControlsController(preview: true);
    addTearDown(controls.dispose);
    await controls.setCustomTemp(55);
    expect(await controls.setPowerControlEnabled(true), isFalse);
    await controls.setThermalLimitDisabled(true);
    expect(await controls.setPowerControlEnabled(true), isTrue);
    expect(await controls.setInputLimit(1), isTrue);
    expect(await controls.setInputLimit(120), isTrue);
    expect(await controls.clearInputLimit(), isTrue);
    expect(controls.inputLimitDisabled, isTrue);
    expect(await controls.setInputLimit(55), isTrue);
    expect(controls.inputLimitDisabled, isFalse);
    expect(await controls.setInputLimit(55.5), isFalse);
    expect(await controls.setPowerControlEnabled(false), isTrue);
    expect(controls.chargingEnabled, isFalse);
    expect(controls.inputLimit, 100);
    expect(controls.inputLimitDisabled, isFalse);
    expect(controls.customTemp, 55);
  });

  test('invalid slider inputs cannot alter demo selections', () async {
    final controls = DeviceControlsController(preview: true);
    addTearDown(controls.dispose);
    for (final value in [double.nan, double.infinity, 24.0, 66.0, 45.5]) {
      expect(await controls.setCustomTemp(value), isFalse);
    }
    expect(await controls.setInputLimit(121), isFalse);
    expect(await controls.setChargeLimit(49), isFalse);
    expect(controls.thermalPreset, ThermalPreset.stock);
    expect(controls.customTemp, 45);
    expect(controls.inputLimit, 100);
    expect(controls.chargeLimit, 100);
    expect(controls.lastError, isNotNull);
    expect(await controls.setChargeLimit(80), isTrue);
    expect(controls.lastError, isNull);
  });

  test(
    'preview changes are local to its repository and do not persist',
    () async {
      final first = DeviceControlsController(preview: true);
      final second = DeviceControlsController(preview: true);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.setBypassRequested(true);
      expect(first.bypassRequested, isTrue);
      expect(second.bypassRequested, isFalse);
      await first.refresh();
      expect(first.bypassRequested, isTrue);
    },
  );
}
