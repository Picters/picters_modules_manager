import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/widgets.dart';

/// The optimistic position a jelly switch takes on tap has to be given back
/// when the action resolves — including when it resolves having changed
/// nothing, which is what happens whenever the user declines one of the
/// dependency confirmations. Waiting for the reported value to move leaves the
/// switch stuck in the position the user just backed out of.
void main() {
  JellySwitch switchOf(WidgetTester tester) =>
      tester.widget<JellySwitch>(find.byType(JellySwitch));

  Widget host({
    required bool value,
    required Future<void> Function(bool) onChanged,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: JellySwitchTile(
            title: 'Title',
            subtitle: 'Subtitle',
            value: value,
            onChanged: onChanged,
          ),
        ),
      );

  testWidgets('moves the instant it is tapped, before the action runs',
      (tester) async {
    var started = false;
    await tester.pumpWidget(host(
      value: false,
      onChanged: (_) async => started = true,
    ));

    await tester.tap(find.byType(JellySwitchTile));
    await tester.pump();

    expect(switchOf(tester).value, isTrue, reason: 'shows the target at once');
    expect(started, isFalse, reason: 'the work is deferred a beat');

    await tester.pumpAndSettle();
    expect(started, isTrue);
  });

  testWidgets('reverts when the action leaves the value unchanged',
      (tester) async {
    // Stands in for a declined confirmation: awaited, does nothing.
    await tester.pumpWidget(host(value: false, onChanged: (_) async {}));

    await tester.tap(find.byType(JellySwitchTile));
    await tester.pump();
    expect(switchOf(tester).value, isTrue);

    await tester.pumpAndSettle();
    expect(switchOf(tester).value, isFalse,
        reason: 'nothing changed, so it must not stay flipped');
  });

  testWidgets('holds the new position when the value does follow',
      (tester) async {
    var value = false;
    late StateSetter setOuter;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            setOuter = setState;
            return JellySwitchTile(
              title: 'Title',
              subtitle: 'Subtitle',
              value: value,
              onChanged: (v) async => setOuter(() => value = v),
            );
          },
        ),
      ),
    ));

    await tester.tap(find.byType(JellySwitchTile));
    await tester.pumpAndSettle();

    expect(value, isTrue);
    expect(switchOf(tester).value, isTrue);
  });

  testWidgets('ignores a second tap while the first is still running',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(host(
      value: false,
      onChanged: (_) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      },
    ));

    await tester.tap(find.byType(JellySwitchTile));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.byType(JellySwitchTile));
    await tester.pumpAndSettle();

    expect(calls, 1);
  });
}
