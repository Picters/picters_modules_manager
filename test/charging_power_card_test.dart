import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/charging_power_card.dart';
import 'package:picters_modules_manager/theme.dart';
import 'package:picters_modules_manager/device_controls.dart';

void main() {
  testWidgets(
    'thermal Off gates charging and leaving Off restores its defaults',
    (tester) async {
      final controls = DeviceControlsController(preview: true);
      addTearDown(controls.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: ChargingPowerCard(preview: true, controller: controls),
          ),
        ),
      );
      Switch toggle() => tester.widget<Switch>(find.byType(Switch));
      expect(toggle().onChanged, isNull);
      await tester.tap(find.text('Charging power'));
      await tester.pumpAndSettle();
      expect(
        find.text(DeviceControlsController.powerRequiresThermalOff),
        findsNothing,
      );
      expect(controls.chargingEnabled, isFalse);
      await controls.setThermalLimitDisabled(true);
      await tester.pumpAndSettle();
      expect(toggle().onChanged, isNotNull);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsOneWidget);
      await controls.setInputLimit(55);
      await controls.setCustomTemp(50);
      await tester.pumpAndSettle();
      expect(controls.chargingEnabled, isFalse);
      expect(controls.inputLimit, 100);
      expect(find.byType(Slider), findsNothing);
      expect(toggle().onChanged, isNull);
    },
  );

  testWidgets('power selector covers 1–120 W and separates Off', (
    tester,
  ) async {
    final controls = DeviceControlsController(preview: true);
    addTearDown(controls.dispose);
    await controls.setThermalLimitDisabled(true);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: ChargingPowerCard(preview: true, controller: controls),
        ),
      ),
    );
    await tester.tap(find.text('Charging power'));
    await tester.pumpAndSettle();
    Slider slider() => tester.widget<Slider>(find.byType(Slider));
    for (final watts in [1, 55, 120]) {
      final selected = (watts - 1) / 134;
      slider().onChanged!(selected);
      slider().onChangeEnd!(selected);
      await tester.pumpAndSettle();
      expect(find.text('$watts W'), findsNWidgets(watts == 55 ? 1 : 2));
      expect(find.text('Off'), findsNothing);
    }
    slider().onChanged!(1);
    slider().onChangeEnd!(1);
    await tester.pumpAndSettle();
    expect(find.text('Off'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNothing);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('100 W'), findsOneWidget);
    expect(find.text('Off'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
