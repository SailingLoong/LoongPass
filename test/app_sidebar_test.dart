import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:forui/forui.dart';

import '../lib/app_sidebar.dart';
import '../lib/ui_preferences.dart';
import 'desktop_test_app.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    UiPreferences? preferences,
    double width = 1024,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      DesktopTestApp(
        home: Scaffold(
          body: AppWorkspace(
            preferences: preferences,
            sections: const {WorkspaceSection.models: Text('Magpie models')},
            pages: const {
              ManagedApp.zcode: Text('ZCode content'),
              ManagedApp.qoder: TextField(key: Key('draft')),
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> order(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('平台顺序'));
    await tester.pumpAndSettle();
  }

  testDesktopWidgets(
    'platform selection keeps button semantics when changing to WorkBuddy CN',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await mount(tester);
        final selector = find.byKey(const Key('platform-filter'));
        final node = tester.getSemantics(selector);
        final before = node.getSemanticsData();
        expect(before.flagsCollection.isTextField, isFalse);
        expect(before.flagsCollection.isButton, isTrue);
        tester.semantics.tap(find.semantics.byLabel(before.label));
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel('WorkBuddy · 国内版'), findsOneWidget);
        await tester.tap(find.text('WorkBuddy · 国内版').last);
        await tester.pumpAndSettle();
        final after = tester.getSemantics(selector).getSemanticsData();
        expect(after.flagsCollection.isTextField, isFalse);
        expect(after.flagsCollection.isButton, isTrue);
        expect(after.label, contains('WorkBuddy · 国内版'));
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testDesktopWidgets(
    'platform selector preserves regional choices and unfinished input',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const Key('platform-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Qoder · 海外版').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('draft')), 'keep me');
      await tester.tap(find.byKey(const Key('nav-models')));
      await tester.pumpAndSettle();
      expect(find.text('Magpie models'), findsOneWidget);
      await tester.tap(find.byKey(const Key('nav-accounts')));
      await tester.pumpAndSettle();
      expect(find.text('keep me'), findsOneWidget);
      await tester.tap(find.byKey(const Key('toggle-sidebar')));
      await tester.pumpAndSettle();
      expect(find.text('keep me'), findsOneWidget);
      expect(findTooltip('账号与积分'), findsOneWidget);
    },
  );

  testDesktopWidgets(
    'platform drag sorting stays available in settings and persists',
    (tester) async {
      String? stored;
      final prefs = UiPreferences(write: (value) async => stored = value);
      addTearDown(prefs.dispose);
      await mount(tester, preferences: prefs);
      await order(tester);
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
      await prefs.saved;
      expect(prefs.appOrder.first, ManagedApp.qoder);
      final restored = UiPreferences(read: () async => stored);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.appOrder.first, ManagedApp.qoder);
      await tester.ensureVisible(find.text('恢复默认应用顺序'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('恢复默认应用顺序'));
      await tester.pumpAndSettle();
      expect(prefs.appOrder.first, ManagedApp.zcode);
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );

  testDesktopWidgets('keyboard can reorder platforms without navigating away', (
    tester,
  ) async {
    final prefs = UiPreferences();
    addTearDown(prefs.dispose);
    await mount(tester, preferences: prefs);
    await order(tester);
    final button = find.descendant(
      of: find.byKey(const Key('app-qoder')),
      matching: find.byType(FButton),
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
    expect(prefs.appOrder[1], ManagedApp.qoder);
    expect(find.text('平台偏好'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
