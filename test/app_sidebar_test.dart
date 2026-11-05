import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/app_sidebar.dart';

void main() {
  Future<void> mount(WidgetTester tester, {double width = 1280, double height = 800}) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AppWorkspace(
      pages: const {
        ManagedApp.zcode: Text('ZCode content'),
        ManagedApp.qoder: TextField(key: Key('draft')),
        ManagedApp.minimax: Text('MiniMax not connected'),
        ManagedApp.workbuddy: Text('WorkBuddy not connected'),
      },
    ))));
  }
  testWidgets('four app buttons navigate without account actions', (tester) async {
    await mount(tester);
    expect(find.text('ZCode content'), findsOneWidget);
    for (final app in ManagedApp.values) {
      await tester.tap(find.byKey(ValueKey('app-${app.name}')));
      await tester.pumpAndSettle();
      expect(tester.widget<Semantics>(find.byKey(ValueKey('selected-${app.name}'))).properties.selected, isTrue);
    }
    expect(find.text('WorkBuddy not connected'), findsOneWidget);
    expect(find.text('ZCode content'), findsNothing);
  });
  testWidgets('navigation and repeated clicks preserve an unfinished form', (tester) async {
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
    expect(tester.getSize(find.byKey(const Key('app-sidebar'))).width, 76);
  });
}
