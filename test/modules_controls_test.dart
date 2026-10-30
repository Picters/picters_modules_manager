import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/app_shell.dart';
import 'package:picters_modules_manager/module_info.dart';
import 'package:picters_modules_manager/preview_backend.dart';
import 'package:picters_modules_manager/theme.dart';
import 'package:picters_modules_manager/widgets.dart';

void main() {
  testWidgets('Wi-Fi group is inert until Inject is applied', (tester) async {
    tester.view.physicalSize = const Size(417, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    final controller = createPreviewController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: AppShell(controller: controller, preview: true),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.tap(find.bySemanticsLabel('Modules'));
    await tester.pumpAndSettle();
    final group = find.byKey(const ValueKey('mg-wifi'));
    final closedHeight = tester.getSize(group).height;
    await tester.tap(find.text('Wi-Fi adapters'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(tester.getSize(group).height, closedHeight);
    final action = controller.setWifiMode(WifiMode.inject);
    await tester.pump(const Duration(milliseconds: 500));
    await action;
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wi-Fi adapters'));
    await tester.pumpAndSettle();
    expect(tester.getSize(group).height, greaterThan(closedHeight));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets('compact search and sliding module filters work together', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(417, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    final controller = createPreviewController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: AppShell(controller: controller, preview: true),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.tap(find.bySemanticsLabel('Modules'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(TextField)).height, 44);
    expect(find.byType(SegmentedButton), findsNothing);
    await tester.tap(find.text('Loaded'));
    await tester.pumpAndSettle();
    final picker = tester.widget<JellySegmented>(
      find.byWidgetPredicate((w) => w is JellySegmented),
    );
    expect(picker.selected.toString(), endsWith('.loaded'));
    expect(find.text('Wi-Fi adapters'), findsNothing);
    await tester.enterText(find.byType(TextField), 'btusb');
    await tester.pumpAndSettle();
    expect(find.text('Results'), findsOneWidget);
    expect(find.text('btusb'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });
}
