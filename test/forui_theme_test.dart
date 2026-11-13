import 'desktop_test_app.dart';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;

import '../lib/main.dart';
import '../lib/ui_preferences.dart';

void main() {
  testDesktopWidgets(
    'settings use Forui controls and retain the selected preferences',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final preferences = UiPreferences();
      addTearDown(preferences.dispose);
      await tester.pumpWidget(AccountToolApp(preferences: preferences));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-settings')));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate((widget) => widget is FSelect<ThemeMode>),
        findsOneWidget,
      );
      expect(find.widgetWithText(FSwitch, '精简导航'), findsOneWidget);
      expect(find.byType(FButton), findsWidgets);
      await tester.tap(find.text('跟随系统'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('深色').last);
      await tester.pumpAndSettle();
      expect(preferences.themeMode, ThemeMode.dark);
      await tester.tap(find.text('紧凑'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('舒适').last);
      await tester.pumpAndSettle();
      expect(preferences.comfortable, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testDesktopWidgets(
    'application uses the official Forui desktop theme and locale',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final preferences = UiPreferences();
      addTearDown(preferences.dispose);
      await tester.pumpWidget(AccountToolApp(preferences: preferences));
      await tester.pumpAndSettle();

      expect(find.byType(FTheme), findsOneWidget);
      final context = tester.element(find.byKey(const Key('app-sidebar')));
      expect(context.theme.colors, FTheme.neutral.light.desktop.colors);
      expect(
        context.theme.typography.body.fontFamily,
        FTypeface.defaultFontFamily,
      );
      expect(context.theme.typography.body.fontFamilyFallback, [
        'SourceHanSansSC',
      ]);
      expect(
        context.theme.typography.body.sm.fontSize,
        FTheme.neutral.light.desktop.typography.body.sm.fontSize,
      );
      expect(Localizations.localeOf(context).languageCode, 'zh');

      preferences.setTheme(ThemeMode.dark);
      await tester.pumpAndSettle();
      expect(context.theme.colors, FTheme.neutral.dark.desktop.colors);
      await tester.tap(find.byKey(const Key('nav-settings')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('invitation-workbuddy')));
      await tester.tap(find.text('WorkBuddy 邀请设置'));
      await tester.pumpAndSettle();
      final invitation = tester.element(
        find.byKey(const Key('workbuddy-invitation-code')),
      );
      expect(invitation.theme.colors, FTheme.neutral.dark.desktop.colors);
      preferences.setTheme(ThemeMode.light);
      await tester.pumpAndSettle();
      expect(context.theme.colors, FTheme.neutral.light.desktop.colors);
      expect(tester.takeException(), isNull);
    },
  );
}
