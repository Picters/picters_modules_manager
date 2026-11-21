import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/app_bottom_bar.dart';
import 'package:picters_modules_manager/app_shell.dart';
import 'package:picters_modules_manager/perf_info.dart';
import 'package:picters_modules_manager/preview_backend.dart';
import 'package:picters_modules_manager/theme.dart';
import 'package:picters_modules_manager/widgets.dart';

void main() {
  testWidgets(
    'preview keeps original dock, Wi-Fi selector and Performance interface',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      final controller = createPreviewController();
      try {
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(Brightness.dark),
            home: AppShell(controller: controller, preview: true),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        expect(find.text('Xiaomi 17'), findsNothing);
        expect(find.text('PICTERS'), findsNothing);
        expect(find.text('Stock Wi-Fi'), findsOneWidget);
        expect(find.text('Inject'), findsOneWidget);
        expect(find.byType(AppBottomBar), findsOneWidget);
        expect(find.byType(NavigationBar), findsNothing);
        expect(tester.takeException(), isNull);

        await tester.tap(find.bySemanticsLabel('Performance'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('Full profile'), findsOneWidget);
        expect(find.text('CPU/GPU'), findsOneWidget);
        final picker = find.byKey(const ValueKey('performance-profile-picker'));
        expect(picker, findsOneWidget);
        expect(find.text('Gaming'), findsNothing);
        expect(find.byTooltip('Gaming'), findsNothing);
        expect(find.text('Custom throttling'), findsOneWidget);
        expect(find.text('Battery controls'), findsNothing);
        double rowHeight(String title) => tester
            .getSize(
              find
                  .ancestor(
                    of: find.text(title),
                    matching: find.byType(ListTile),
                  )
                  .first,
            )
            .height;
        expect(rowHeight('Custom throttling'), rowHeight('Keep after reboot'));
        expect(find.text('Charging power'), findsNothing);
        expect(find.text('Fast charging with screen on'), findsNothing);

        await tester.tap(find.byTooltip('Balanced'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));
        expect(controller.perf.profile, PerfProfile.balanced);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Full'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(controller.perf.profile, PerfProfile.full);
        expect(controller.perf.state.gamingActive, isFalse);
        expect(
          tester
              .widgetList<ReelPill>(find.byType(ReelPill))
              .every((pill) => pill.accent == null),
          isTrue,
        );
        expect(tester.takeException(), isNull);

        await tester.tap(find.byTooltip('Settings'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('Hide Performance screen'), findsNothing);
        expect(find.text('GitHub'), findsOneWidget);
        expect(find.text('github.com/Picters'), findsOneWidget);
        expect(find.textContaining('Auto-loads every module'), findsNothing);
        expect(
          rowHeight('Load modules on boot'),
          rowHeight('Add to home screen'),
        );
        expect(
          rowHeight('Collect diagnostics'),
          rowHeight('Add to home screen'),
        );
        expect(rowHeight('Picters'), rowHeight('Add to home screen'));

        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      }
    },
  );
}
