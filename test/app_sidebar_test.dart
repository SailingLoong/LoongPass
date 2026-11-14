import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:forui/forui.dart';

import '../lib/app_navigation_item.dart';
import '../lib/app_sidebar.dart';
import '../lib/ui_preferences.dart';
import 'desktop_test_app.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    UiPreferences? preferences,
    double width = 1024,
    double height = 900,
    double textScale = 1,
    Set<ManagedApp>? enabledApps,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      DesktopTestApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: AppWorkspace(
            preferences: preferences,
            enabledApps: enabledApps,
            sections: const {
              WorkspaceSection.overview: Text('Overview'),
              WorkspaceSection.accounts: Text('All accounts'),
              WorkspaceSection.models: Text('Magpie models'),
              WorkspaceSection.activity: Text('Recent claims'),
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

  for (final (width, textScale, sidebarWidth) in [
    (1024.0, 1.0, 208.0),
    (1280.0, 1.3, 270.4),
    (1920.0, 2.0, 416.0),
    (1024.0, 0.8, 208.0),
  ]) {
    testDesktopWidgets(
      'expanded navigation keeps names clear of actions at $width and scale $textScale',
      (tester) async {
        await tester.runAsync(() async {
          final inter = FontLoader(FTypeface.defaultFontFamily)
            ..addFont(
              rootBundle.load('packages/forui/assets/fonts/inter/Inter.ttf'),
            );
          final sourceHan = FontLoader('SourceHanSansSC')
            ..addFont(rootBundle.load('assets/fonts/SourceHanSansSC-VF.ttf'));
          await Future.wait([inter.load(), sourceHan.load()]);
        });
        await mount(tester, width: width, textScale: textScale);
        expect(
          tester.getSize(find.byKey(const Key('app-sidebar'))).width,
          closeTo(sidebarWidth, 0.001),
        );
        expect(find.byKey(const Key('show-apps')), findsNothing);
        final accountLabel = find.descendant(
          of: find.byKey(const Key('nav-accounts')),
          matching: find.text('账号与积分'),
        );
        final labelLeft = tester.getTopLeft(accountLabel).dx;
        for (final app in ManagedApp.values) {
          final button = find.byKey(ValueKey('app-${app.name}'));
          final label = find.descendant(
            of: button,
            matching: find.text(app.label),
          );
          final paragraph = tester.renderObject<RenderParagraph>(label);
          final boxes = paragraph.getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: app.label.length),
          );
          expect(paragraph.didExceedMaxLines, isFalse, reason: app.label);
          expect(tester.getTopLeft(label).dx, labelLeft, reason: app.label);
          expect(
            tester.getSize(button).height,
            greaterThanOrEqualTo(36),
            reason: app.label,
          );
          expect(paragraph.textScaler.scale(14), 14 * textScale);
          expect(
            paragraph.localToGlobal(Offset(boxes.last.right, 0)).dx,
            lessThan(
              tester.getRect(find.byKey(ValueKey('hide-${app.name}'))).left,
            ),
            reason: app.label,
          );
          if (app.regionCode == 'CN') {
            final badge = find.byKey(ValueKey('region-${app.name}'));
            expect(MediaQuery.textScalerOf(tester.element(badge)).scale(7), 7);
            expect(tester.getSize(badge).height, lessThanOrEqualTo(10));
            expect(tester.getSize(badge).width, lessThan(20));
          }
        }
        final label = find.text('MiniMax CN');
        final before = tester.getRect(label);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: tester.getCenter(label));
        await tester.pumpAndSettle();
        expect(tester.getRect(label), before);
        expect(
          find.byKey(const Key('hide-minimaxCn')).hitTestable(),
          findsOneWidget,
        );
        await mouse.removePointer();
        Focus.of(tester.element(label)).requestFocus();
        await tester.pumpAndSettle();
        expect(tester.getRect(label), before);
        expect(
          find.byKey(const Key('hide-minimaxCn')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final (wide, narrow, textScale, sidebarWidth) in [
    (1024.0, 800.0, 1.0, 208.0),
    (1920.0, 1080.0, 2.0, 416.0),
  ]) {
    testDesktopWidgets(
      'automatic compact navigation preserves preferences and drafts at scale $textScale',
      (tester) async {
        final writes = <String>[];
        final preferences = UiPreferences(
          write: (value) async => writes.add(value),
        );
        addTearDown(preferences.dispose);
        await mount(
          tester,
          preferences: preferences,
          width: wide,
          textScale: textScale,
        );
        await tester.tap(find.byKey(const Key('app-qoder')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('draft')),
          'keep on resize',
        );

        tester.view.physicalSize = Size(narrow, 900);
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byKey(const Key('app-sidebar'))).width, 56);
        expect(preferences.collapsed, isFalse);
        expect(writes, isEmpty);
        expect(find.text('keep on resize'), findsOneWidget);

        tester.view.physicalSize = Size(wide, 900);
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(const Key('app-sidebar'))).width,
          closeTo(sidebarWidth, 0.001),
        );
        await tester.tap(find.byKey(const Key('toggle-sidebar')));
        await tester.pumpAndSettle();
        await preferences.saved;
        expect(preferences.collapsed, isTrue);
        expect(writes, hasLength(1));

        tester.view.physicalSize = Size(narrow, 900);
        await tester.pumpAndSettle();
        tester.view.physicalSize = Size(wide, 900);
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byKey(const Key('app-sidebar'))).width, 56);
        expect(preferences.collapsed, isTrue);
        expect(writes, hasLength(1));
        expect(find.text('keep on resize'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testDesktopWidgets('truncated expanded navigation exposes a mouse tooltip', (
    tester,
  ) async {
    await tester.pumpWidget(
      DesktopTestApp(
        home: Center(
          child: SizedBox(
            width: 96,
            child: SidebarNavigationButton(
              label: 'MiniMax CN',
              icon: const Icon(FLucideIcons.wallet),
              compact: false,
              selected: false,
              onPressed: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final label = find.text('MiniMax CN');
    expect(
      tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
      isTrue,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(
      location: tester.getCenter(find.byType(SidebarNavigationButton)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('MiniMax CN'), findsNWidgets(2));
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(800, 632), const Size(1024, 480)]) {
    testDesktopWidgets(
      'main navigation stays visible while applications scroll at $size',
      (tester) async {
        await mount(tester, width: size.width, height: size.height);
        final positions = <WorkspaceSection, Rect>{};
        for (final section in WorkspaceSection.values) {
          final button = find.byKey(ValueKey('nav-${section.name}'));
          expect(button.hitTestable(), findsOneWidget);
          positions[section] = tester.getRect(button);
        }
        final list = find.byKey(const PageStorageKey('account-app-scroll'));
        final scrollable = find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        );
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(list),
            scrollDelta: const Offset(0, 600),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.state<ScrollableState>(scrollable).position.pixels,
          greaterThan(0),
        );
        for (final section in WorkspaceSection.values) {
          final button = find.byKey(ValueKey('nav-${section.name}'));
          expect(button.hitTestable(), findsOneWidget);
          expect(tester.getRect(button), positions[section]);
        }
        expect(find.byKey(const Key('app-all')).hitTestable(), findsOneWidget);
        await tester.tap(find.byKey(const Key('app-codex')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-models')));
        await tester.pumpAndSettle();
        expect(find.text('Magpie models'), findsOneWidget);
        await tester.tap(find.byKey(const Key('nav-accounts')));
        await tester.pumpAndSettle();
        expect(find.text('Codex 尚未接入'), findsOneWidget);
        await tester.tap(find.byKey(const Key('nav-activity')));
        await tester.pumpAndSettle();
        expect(find.text('Recent claims'), findsOneWidget);
        await tester.tap(find.byKey(const Key('nav-settings')));
        await tester.pumpAndSettle();
        expect(find.text('平台偏好'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
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
    'nested application navigation preserves regional choices and unfinished input',
    (tester) async {
      await mount(tester);
      expect(find.byKey(const Key('platform-filter')), findsNothing);
      expect(find.text('Qoder CN'), findsOneWidget);
      await tester.tap(find.byKey(const Key('app-qoder')));
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

  testDesktopWidgets(
    'the group collapses without navigating and all apps can be restored in a narrow window',
    (tester) async {
      final preferences = UiPreferences();
      addTearDown(preferences.dispose);
      await mount(
        tester,
        preferences: preferences,
        width: 480,
        enabledApps: {ManagedApp.zcode, ManagedApp.qoder},
      );
      await tester.tap(find.byKey(const Key('app-zcode')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-accounts')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('account-apps')), findsNothing);
      expect(find.text('ZCode content'), findsOneWidget);
      await tester.tap(find.byKey(const Key('nav-accounts')));
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      for (final app in [ManagedApp.zcode, ManagedApp.qoder]) {
        await mouse.moveTo(
          tester.getCenter(find.byKey(ValueKey('app-${app.name}'))),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('hide-${app.name}')));
        await tester.pumpAndSettle();
      }
      await mouse.removePointer();
      expect(find.text('All accounts'), findsOneWidget);
      expect(find.byKey(const Key('app-all')), findsOneWidget);
      await tester.tap(find.byKey(const Key('show-apps')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('show-workbuddy')), findsNothing);
      await tester.tap(find.byKey(const Key('show-zcode')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-zcode')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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
