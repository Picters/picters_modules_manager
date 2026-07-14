import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:picters_modules_manager/main.dart';

void main() {
  testWidgets('shows the app bar title', (WidgetTester tester) async {
    await tester.pumpWidget(const PictersModulesManagerApp());
    await tester.pumpAndSettle();

    expect(find.text('Picters Modules Manager'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });
}
