import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/widgets.dart';

void main() {
  testWidgets('frequency chip stays compact inside a tall row and stable at Max', (tester) async {
    Widget screen(String text) => MaterialApp(home: Scaffold(body: ListTile(
      title: const Text('Adreno GPU'),
      subtitle: const Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [Text('up to 1200 MHz'), SizedBox(height: 20), Text('Additional row content')]),
      trailing: ReelPill(text: text),
    )));
    await tester.pumpWidget(screen('1200 MHz'));
    await tester.pumpAndSettle();
    final before = tester.getSize(find.byType(ReelPill));
    expect(before.height, lessThanOrEqualTo(34));
    await tester.pumpWidget(screen('Max'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ReelPill)), before);
    expect(tester.takeException(), isNull);
  });
}
