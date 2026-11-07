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

  test('unverified production cannot change thermal settings', () async {
    final controls = DeviceControlsController();
    addTearDown(controls.dispose);
    await controls.init();
    expect(controls.preview, isFalse);
    expect(controls.supported, isFalse);
    expect(
      controls.availabilityMessage,
      contains('Device verification pending'),
    );
    expect(await controls.setCustomTemp(50), isFalse);
    expect(await controls.restoreThermalStock(), isFalse);
    expect(controls.thermalPreset, ThermalPreset.stock);
  });

  test('unverified repository rejects deployment outside controller', () {
    expect(
      UnverifiedDeviceControlsRepository().apply(const DeviceControlSettings()),
      throwsUnsupportedError,
    );
  });

  test(
    'thermal slider, Off, persistence and stock restore remain available',
    () async {
      final controls = DeviceControlsController(preview: true);
      addTearDown(controls.dispose);
      await controls.init();
      expect(controls.thermalSupported, isTrue);
      for (final value in [25.0, 47.0, 65.0]) {
        expect(await controls.setCustomTemp(value), isTrue);
        expect(controls.customTemp, value);
      }
      expect(await controls.setThermalLimitDisabled(true), isTrue);
      expect(await controls.setBootPersistence(true), isTrue);
      expect(controls.thermalLimitDisabled, isTrue);
      expect(controls.state.settings.persistOnBoot, isTrue);
      expect(await controls.restoreThermalStock(), isTrue);
      expect(controls.thermalPreset, ThermalPreset.stock);
      expect(controls.customTemp, 45);
      expect(controls.thermalLimitDisabled, isFalse);
      expect(controls.state.settings.persistOnBoot, isTrue);
    },
  );

  test(
    'invalid temperatures do not alter the active thermal profile',
    () async {
      final controls = DeviceControlsController(preview: true);
      addTearDown(controls.dispose);
      for (final value in [double.nan, double.infinity, 24.0, 66.0, 45.5]) {
        expect(await controls.setCustomTemp(value), isFalse);
      }
      expect(controls.thermalPreset, ThermalPreset.stock);
      expect(controls.lastError, isNotNull);
      expect(await controls.setCustomTemp(50), isTrue);
      expect(controls.lastError, isNull);
    },
  );

  test('demo thermal profiles stay local to their repository', () async {
    final first = DeviceControlsController(preview: true);
    final second = DeviceControlsController(preview: true);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.setCustomTemp(55);
    await first.refresh();
    expect(first.customTemp, 55);
    expect(second.customTemp, 45);
  });
}
