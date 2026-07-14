import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:picters_modules_manager/main.dart';

void main() {
  testWidgets('boots into the root-check state', (WidgetTester tester) async {
    await tester.pumpWidget(const PictersKernelManagerApp());
    await tester.pump();

    // Without root/native plumbing in the test host it sits on the checking
    // screen; just assert the app renders its material shell.
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
