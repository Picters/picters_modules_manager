import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:picters_modules_manager/main.dart';

void main() {
  testWidgets('boots into the root-check state', (WidgetTester tester) async {
    // The controller kicks off a real root probe (Process.start('su')) from
    // initState; run inside runAsync so that IO lives on the real event loop
    // instead of leaving a FakeAsync timer pending when the test ends.
    await tester.runAsync(() async {
      await tester.pumpWidget(const PictersKernelManagerApp());
      await tester.pump();

      // Without root/native plumbing in the test host it sits on the checking
      // screen; just assert the app renders its material shell.
      expect(find.byType(MaterialApp), findsOneWidget);

      // Tear the widget down so the controller's timers are cancelled.
      await tester.pumpWidget(const SizedBox());
    });
  });
}
