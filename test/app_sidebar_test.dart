import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
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
    Set<ManagedApp>? enabledApps,
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
            enabledApps: enabledApps,
            sections: const {
              WorkspaceSection.accounts: Text('All accounts'),
              WorkspaceSection.models: Text('Magpie models'),
            },
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

  testDesktopWidgets('models navigation can expand before the catalog loads', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const Key('nav-models')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('toggle-models')), findsOneWidget);
    await tester.tap(find.byKey(const Key('toggle-models')));
    await tester.pumpAndSettle();
    expect(find.text('暂无模型'), findsOneWidget);
    expect(find.text('Magpie models'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final width in [480.0, 1024.0]) {
    testDesktopWidgets('model selection uses the supplied order at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? stored;
      final preferences = UiPreferences(write: (value) async => stored = value);
      final selection = ValueNotifier<String?>(null);
      addTearDown(preferences.dispose);
      addTearDown(selection.dispose);
      preferences.setAppsExpanded(false);
      await tester.pumpWidget(
        DesktopTestApp(
          home: Scaffold(
            body: ValueListenableBuilder<String?>(
              valueListenable: selection,
              builder: (context, selected, _) => AppWorkspace(
                preferences: preferences,
                modelIds: const ['auto', 'MiniMax-M3', 'deepseek-flash'],
                selectedModelId: selected,
                onSelectModel: (id) => selection.value = id,
                pages: const {ManagedApp.qoder: TextField(key: Key('draft'))},
                sections: {
                  WorkspaceSection.accounts: const Text('All accounts'),
                  WorkspaceSection.models: Text(
                    'Selection ${selected ?? 'all'}',
                  ),
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('toggle-models')));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const Key('model-nav-MiniMax-M3'))).dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const Key('model-nav-deepseek-flash')))
              .dy,
        ),
      );
      await tester.tap(find.byKey(const Key('model-nav-deepseek-flash')));
      await tester.pumpAndSettle();
      expect(selection.value, 'deepseek-flash');
      expect(find.text('Selection deepseek-flash'), findsOneWidget);
      await tester.tap(find.byKey(const Key('nav-accounts')));
      await tester.pumpAndSettle();
      expect(find.text('All accounts'), findsOneWidget);
      await tester.tap(find.byKey(const Key('nav-models')));
      await tester.pumpAndSettle();
      expect(selection.value, isNull);
      expect(find.text('Selection all'), findsOneWidget);
      await preferences.saved;
      final restored = UiPreferences(read: () async => stored);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.modelsExpanded, width >= 760);
      expect(restored.appsExpanded, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testDesktopWidgets(
    'application navigation exposes buttons to the macOS accessibility bridge',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await mount(tester);
        final app = find.bySemanticsLabel('WorkBuddy');
        final before = tester.getSemantics(app).getSemanticsData();
        expect(before.flagsCollection.isTextField, isFalse);
        expect(before.flagsCollection.isButton, isTrue);
        tester.semantics.tap(find.semantics.byLabel(before.label));
        await tester.pumpAndSettle();
        expect(find.text('WorkBuddy 尚未接入'), findsOneWidget);
        final after = tester.getSemantics(app).getSemanticsData();
        expect(after.flagsCollection.isTextField, isFalse);
        expect(after.flagsCollection.isButton, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testDesktopWidgets(
    'nested application navigation shows full names and preserves unfinished input',
    (tester) async {
      await tester.runAsync(() async {
        final inter = FontLoader(FTypeface.defaultFontFamily)
          ..addFont(
            rootBundle.load('packages/forui/assets/fonts/inter/Inter.ttf'),
          );
        await inter.load();
      });
      final preferences = UiPreferences(read: () async => '{"collapsed":true}');
      addTearDown(preferences.dispose);
      await preferences.load();
      await mount(tester, preferences: preferences);
      expect(tester.getSize(find.byKey(const Key('app-sidebar'))).width, 192);
      expect(find.byKey(const Key('platform-filter')), findsNothing);
      expect(find.byKey(const Key('toggle-sidebar')), findsNothing);
      expect(find.byKey(const Key('app-all')), findsNothing);
      expect(find.text('Qoder CN'), findsOneWidget);
      for (final app in ManagedApp.values) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.text(app.label),
            matching: find.byType(RichText),
          ),
        );
        expect(
          paragraph.didExceedMaxLines,
          isFalse,
          reason: '${app.label} should be fully visible',
        );
      }
      await tester.tap(find.byKey(const Key('app-qoder')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('draft')), 'keep me');
      await tester.tap(find.byKey(const Key('nav-models')));
      await tester.pumpAndSettle();
      expect(find.text('Magpie models'), findsOneWidget);
      await tester.tap(find.byKey(const Key('nav-accounts')));
      await tester.pumpAndSettle();
      expect(find.text('All accounts'), findsOneWidget);
      await tester.tap(find.byKey(const Key('app-qoder')));
      await tester.pumpAndSettle();
      expect(find.text('keep me'), findsOneWidget);
      tester.view.physicalSize = const Size(480, 900);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(const Key('app-sidebar'))).width, 56);
      expect(findTooltip('账号与积分'), findsOneWidget);
      await tester.tap(find.byKey(const Key('app-brand')));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(const Key('app-sidebar'))).width, 56);
      expect(find.text('keep me'), findsOneWidget);
      tester.view.physicalSize = const Size(1024, 900);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(const Key('app-sidebar'))).width, 192);
      expect(find.text('keep me'), findsOneWidget);
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
      final source = tester.getCenter(
        find.descendant(
          of: find.byKey(const Key('app-order')),
          matching: find.byKey(const Key('drag-qoder')),
        ),
      );
      final target = tester.getCenter(
        find.descendant(
          of: find.byKey(const Key('app-order')),
          matching: find.byKey(const Key('app-zcode')),
        ),
      );
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
      of: find.descendant(
        of: find.byKey(const Key('app-order')),
        matching: find.byKey(const Key('app-qoder')),
      ),
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

  testDesktopWidgets(
    'hiding the active app returns to all and showing it preserves its draft',
    (tester) async {
      final preferences = UiPreferences();
      addTearDown(preferences.dispose);
      await mount(tester, preferences: preferences);
      await tester.tap(find.byKey(const Key('app-qoder')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('draft')), 'keep draft');
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: tester.getCenter(find.byKey(const Key('app-qoder'))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('hide-qoder')));
      await tester.pumpAndSettle();
      expect(find.text('All accounts'), findsOneWidget);
      expect(find.byKey(const Key('app-qoder')), findsNothing);
      expect(preferences.isAppVisible(ManagedApp.qoder), isFalse);
      await tester.tap(find.byKey(const Key('show-apps')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('show-qoder')));
      await tester.pumpAndSettle();
      expect(preferences.isAppVisible(ManagedApp.qoder), isTrue);
      expect(find.text('All accounts'), findsOneWidget);
      await tester.tap(find.byKey(const Key('app-qoder')));
      await tester.pumpAndSettle();
      expect(find.text('keep draft'), findsOneWidget);
      await mouse.removePointer();
    },
  );

  for (final width in [480.0, 1024.0]) {
    testDesktopWidgets(
      'account summary and spacious app disclosure are independent at $width',
      (tester) async {
        final preferences = UiPreferences();
        addTearDown(preferences.dispose);
        await mount(
          tester,
          preferences: preferences,
          width: width,
          enabledApps: {ManagedApp.zcode, ManagedApp.qoder},
        );
        await tester.tap(find.byKey(const Key('app-zcode')));
        await tester.pumpAndSettle();
        final disclosure = tester.getRect(
          find.byKey(const Key('toggle-account-apps')),
        );
        final parent = tester.getRect(find.byKey(const Key('nav-accounts')));
        expect(disclosure.width, greaterThanOrEqualTo(32));
        expect(disclosure.height, greaterThanOrEqualTo(32));
        expect(disclosure.overlaps(parent), isFalse);
        await tester.tapAt(disclosure.centerLeft + const Offset(2, 0));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('account-apps')), findsNothing);
        expect(find.text('ZCode content'), findsOneWidget);
        await tester.tap(find.byKey(const Key('nav-accounts')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('account-apps')), findsNothing);
        expect(find.text('All accounts'), findsOneWidget);
        expect(find.byKey(const Key('app-all')), findsNothing);
        await tester.tap(find.byKey(const Key('toggle-account-apps')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-accounts')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('account-apps')), findsOneWidget);
        for (final app in [ManagedApp.zcode, ManagedApp.qoder]) {
          await tester.tap(find.byKey(ValueKey('hide-${app.name}')));
          await tester.pumpAndSettle();
        }
        expect(find.text('All accounts'), findsOneWidget);
        expect(find.byKey(const Key('app-all')), findsNothing);
        await tester.tap(find.byKey(const Key('show-apps')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('show-workbuddy')), findsNothing);
        await tester.tap(find.byKey(const Key('show-zcode')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('app-zcode')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testDesktopWidgets(
    'dragging visible apps respects hidden entries and keeps the selected page',
    (tester) async {
      String? stored;
      final preferences = UiPreferences(write: (value) async => stored = value);
      addTearDown(preferences.dispose);
      preferences.setAppVisible(ManagedApp.qoderCn, false);
      await mount(tester, preferences: preferences);
      await tester.tap(find.byKey(const Key('app-qoder')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('draft')),
        'persist through drag',
      );
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
      expect(preferences.appOrder.first, ManagedApp.qoder);
      expect(find.text('persist through drag'), findsOneWidget);
      await preferences.saved;
      final restored = UiPreferences(read: () async => stored);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.appOrder.first, ManagedApp.qoder);
      expect(restored.isAppVisible(ManagedApp.qoderCn), isFalse);
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );
}
