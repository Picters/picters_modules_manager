import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/thermal_control_card.dart';
import 'package:picters_modules_manager/theme.dart';
import 'package:picters_modules_manager/device_controls.dart';

class _RecordingRepository extends DemoDeviceControlsRepository {
  int applies = 0;
  @override
  Future<DeviceControlsState> apply(DeviceControlSettings settings) {
    applies++;
    return super.apply(settings);
  }
}

class _BlockingRepository extends DemoDeviceControlsRepository {
  Completer<void>? pending;
  bool fail = false;
  @override
  Future<DeviceControlsState> apply(DeviceControlSettings settings) async {
    await pending?.future;
    if (fail) throw StateError('Profile was not accepted');
    return super.apply(settings);
  }
}

void main() {
  for (final fail in [false, true]) {
    testWidgets('slider stays locked until ${fail ? "failure" : "success"}', (
      tester,
    ) async {
      final repository = _BlockingRepository();
      final controls = DeviceControlsController(repository: repository);
      addTearDown(controls.dispose);
      await controls.setThermalPreset(ThermalPreset.custom);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: ThermalControlCard(preview: true, controller: controls),
          ),
        ),
      );
      await tester.pumpAndSettle();
      repository.pending = Completer<void>();
      repository.fail = fail;
      Slider slider() => tester.widget<Slider>(find.byType(Slider));
      slider().onChanged!(35 / 45);
      slider().onChangeEnd!(35 / 45);
      await tester.pump();
      expect(find.text('60 °C'), findsOneWidget);
      expect(controls.customTemp, 45);
      expect(slider().onChanged, isNull);
      expect(slider().onChangeEnd, isNull);
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect(slider().onChanged, isNull);
      repository.pending!.complete();
      await tester.pumpAndSettle();
      expect(slider().onChanged, isNotNull);
      expect(controls.customTemp, fail ? 45 : 60);
      expect(find.text(fail ? '45 °C' : '60 °C'), findsOneWidget);
    });
  }

  testWidgets(
    'drag previews only; release applies once with shared reboot flag',
    (tester) async {
      final repository = _RecordingRepository();
      final controls = DeviceControlsController(repository: repository);
      addTearDown(controls.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: ThermalControlCard(
              preview: true,
              persistOnBoot: true,
              controller: controls,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom throttling'));
      await tester.pumpAndSettle();
      final before = repository.applies;
      for (final step in [21, 25, 30, 35]) {
        tester.widget<Slider>(find.byType(Slider)).onChanged!(step / 45);
        await tester.pump();
      }
      expect(repository.applies, before);
      expect(controls.customTemp, 45);
      tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(35 / 45);
      await tester.pumpAndSettle();
      expect(repository.applies, before + 1);
      expect(controls.customTemp, 60);
      expect(controls.state.settings.persistOnBoot, isTrue);
    },
  );

  testWidgets(
    'thermal slider snaps by one degree and separates Off from stock',
    (tester) async {
      var haptics = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') haptics++;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: const Scaffold(body: ThermalControlCard(preview: true)),
        ),
      );
      await tester.tap(find.text('Custom throttling'));
      await tester.pumpAndSettle();
      expect(find.text('45 °C'), findsOneWidget);
      Slider slider() => tester.widget<Slider>(find.byType(Slider));
      expect(slider().divisions, 45);
      Color? trackColor() => tester
          .widget<SliderTheme>(
            find
                .ancestor(
                  of: find.byType(Slider),
                  matching: find.byType(SliderTheme),
                )
                .first,
          )
          .data
          .activeTrackColor;
      final middleColor = trackColor();
      slider().onChanged!(29 / 45);
      await tester.pumpAndSettle();
      expect(find.text('54 °C'), findsOneWidget);
      expect(find.textContaining('High temperatures'), findsNothing);
      slider().onChanged!(30 / 45);
      await tester.pumpAndSettle();
      expect(find.text('55 °C'), findsOneWidget);
      expect(find.textContaining('High temperatures'), findsOneWidget);
      slider().onChanged!(40 / 45);
      await tester.pump();
      expect(find.text('65 °C'), findsNWidgets(2));
      expect(trackColor(), const Color(0xFFFF8A80));
      expect(trackColor(), isNot(middleColor));
      slider().onChanged!(0);
      await tester.pump();
      expect(find.text('25 °C'), findsNWidgets(2));
      expect(trackColor(), buildAppTheme(Brightness.dark).colorScheme.primary);
      haptics = 0;

      slider().onChanged!(21 / 45);
      await tester.pump();
      expect(find.text('46 °C'), findsOneWidget);
      expect(haptics, 1);
      slider().onChanged!(21 / 45);
      await tester.pump();
      expect(haptics, 1);
      slider().onChangeEnd!(21 / 45);
      await tester.pumpAndSettle();
      expect(find.text('46 °C'), findsOneWidget);
      final beforeOff = haptics;
      slider().onChanged!(1);
      await tester.pump();
      expect(haptics, beforeOff + 1);
      slider().onChanged!(1);
      await tester.pump();
      expect(haptics, beforeOff + 1);
      slider().onChangeEnd!(1);
      await tester.pumpAndSettle();
      expect(find.text('Off'), findsOneWidget);
      expect(find.textContaining('High temperatures'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsNothing);
      await tester.tap(find.text('Custom throttling'));
      await tester.pumpAndSettle();
      expect(find.text('45 °C'), findsOneWidget);
      expect(find.text('Off'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
