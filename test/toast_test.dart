import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/theme.dart';

void main() {
  for (final direction in [-1.0, 1.0]) {
    testWidgets('toast animates and dismisses horizontally $direction', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showInfo(context, 'Profile applied.'),
                child: const Text('Show'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Show'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      final toast = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(toast.animation!.value, greaterThan(0));
      expect(toast.animation!.value, lessThan(1));
      expect(toast.dismissDirection, DismissDirection.horizontal);
      await tester.pumpAndSettle();
      await tester.drag(
        find.text('Profile applied.'),
        Offset(800 * direction, 0),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
