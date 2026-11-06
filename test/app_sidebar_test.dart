import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import '../lib/app_sidebar.dart';
import '../lib/ui_preferences.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    double width = 1280,
    double height = 800,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppWorkspace(
            pages: const {
              ManagedApp.zcode: Text('ZCode content'),
              ManagedApp.qoder: TextField(key: Key('draft')),
              ManagedApp.minimax: Text('MiniMax not connected'),
              ManagedApp.workbuddy: Text('WorkBuddy not connected'),
            },
          ),
        ),
      ),
    );
  }

  testWidgets(
    'sidebar toggle shares the brand row and model entry stays reachable',
    (tester) async {
      await mount(tester);
      expect(
        (tester.getCenter(find.byKey(const Key('toggle-sidebar'))).dy -
                tester.getCenter(find.text('LoongPass')).dy)
            .abs(),
        lessThan(5),
      );
      await tester.tap(find.byKey(const Key('nav-models')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Magpie'), findsWidgets);
      expect(find.text('尚未启动'), findsWidgets);
      expect(find.textContaining('127.0.0.1'), findsNothing);
    },
  );

  testWidgets(
    'dragging an app preserves selected content and unfinished input',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('app-qoder')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('draft')), 'keep me');
      expect(find.byKey(const Key('drag-qoder')), findsOneWidget);
      final source = tester.getCenter(find.byKey(const Key('drag-qoder')));
      final target = tester.getCenter(find.byKey(const Key('app-zcode')));
      final gesture = await tester.startGesture(
        source,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, -24));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveTo(Offset(source.dx, target.dy + 4));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const Key('app-qoder'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('app-zcode'))).dy),
      );
      expect(find.text('keep me'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('app-zcode')));
      await tester.pumpAndSettle();
      expect(find.text('ZCode content'), findsOneWidget);
    },
  );

  testWidgets('regional app buttons navigate without account actions', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('ZCode content'), findsOneWidget);
    for (final app in ManagedApp.values) {
      await tester.tap(find.byKey(ValueKey('app-${app.name}')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Semantics>(find.byKey(ValueKey('selected-${app.name}')))
            .properties
            .selected,
        isTrue,
      );
    }
    expect(find.text('${ManagedApp.values.last.label} 尚未接入'), findsOneWidget);
    expect(find.text('ZCode content'), findsNothing);
  });
  testWidgets('navigation and repeated clicks preserve an unfinished form', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('app-qoder')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('draft')), 'unfinished note');
    await tester.tap(find.byKey(const ValueKey('app-zcode')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('app-qoder')));
    await tester.tap(find.byKey(const ValueKey('app-qoder')));
    await tester.pump();
    expect(find.text('unfinished note'), findsOneWidget);
  });
  for (final width in [480.0, 760.0, 1280.0]) {
    testWidgets('sidebar fits ${width.toInt()} wide viewport', (tester) async {
      await mount(tester, width: width, height: 360);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('app-workbuddy')).hitTestable(),
        100,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('app-order')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('app-workbuddy')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('app-workbuddy')));
      await tester.pumpAndSettle();
      expect(find.text('WorkBuddy not connected'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('manual collapse keeps app tooltips and content', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const Key('toggle-sidebar')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Qoder'), findsOneWidget);
    expect(find.text('ZCode content'), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('app-sidebar'))).width, 64);
  });

  testWidgets(
    'keyboard move and persisted order keep the selected app on remount',
    (tester) async {
      String? stored;
      final preferences = UiPreferences(write: (value) async => stored = value);
      Future<void> show(UiPreferences state) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppWorkspace(
              preferences: state,
              initialApp: ManagedApp.workbuddy,
              pages: const {ManagedApp.workbuddy: Text('WorkBuddy selected')},
            ),
          ),
        ),
      );
      await show(preferences);
      final button = find.descendant(
        of: find.byKey(const Key('app-workbuddy')),
        matching: find.byType(TextButton),
      );
      Focus.of(
        tester.element(
          find.descendant(of: button, matching: find.byType(Text)).first,
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
      await preferences.saved;
      expect(preferences.appOrder.map((a) => a.name), [
        'zcode',
        'qoderCn',
        'qoder',
        'minimaxCn',
        'workbuddy',
        'minimax',
        'traeCn',
        'lobsterai',
        'loomy',
      ]);
      await tester.pumpWidget(const SizedBox());
      final restored = UiPreferences(read: () async => stored);
      await restored.load();
      await show(restored);
      await tester.pumpAndSettle();
      expect(find.text('WorkBuddy selected'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const Key('app-workbuddy'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('app-minimax'))).dy),
      );
      await tester.tap(find.byKey(const Key('toggle-sidebar')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('region-qoderCn')), findsOneWidget);
      expect(find.byKey(const Key('region-qoder')), findsOneWidget);
      expect(find.text('CN'), findsWidgets);
      expect(find.text('GL'), findsWidgets);
    },
  );
}
