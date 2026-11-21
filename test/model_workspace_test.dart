import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/app_sidebar.dart';
import '../lib/main.dart';
import '../lib/plugin_model_page.dart';
import '../lib/ui_preferences.dart';
import '../lib/workspace_page.dart';
import 'desktop_test_app.dart';
import 'model_workspace_fixture.dart';

void main() {
  testDesktopWidgets(
    'model navigation shows a single stationary page from the first frame',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1080, 748);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final app = ModelWorkspaceFixture();
      addTearDown(app.dispose);
      await tester.pumpWidget(AccountToolApp(application: app));
      await tester.pumpAndSettle();

      final heading = find.byType(WorkspaceHeading);
      final origin = tester.getTopLeft(heading);
      void expectPage(String title) {
        expect(heading, findsOneWidget);
        expect(tester.widget<WorkspaceHeading>(heading).title, title);
        expect(tester.getTopLeft(heading), origin);
      }

      Future<void> open(Finder control, String title) async {
        await tester.tap(control);
        await tester.pump();
        expectPage(title);
        await tester.pump(const Duration(milliseconds: 80));
        expectPage(title);
      }

      final catalog = find.byKey(const Key('nav-models'));
      await open(catalog, '模型连接');
      await open(
        find.byKey(const Key('model-nav-deepseek-flash')),
        'deepseek-flash',
      );
      await open(find.byKey(const Key('model-nav-MiniMax-M3')), 'MiniMax-M3');
      await open(catalog, '模型连接');
      await open(
        find.byKey(const Key('open-model-deepseek-flash')),
        'deepseek-flash',
      );
      await open(find.text('全部模型'), '模型连接');
      await open(find.byKey(const Key('model-nav-auto')), 'LoongPass Auto');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expectPage('模型连接');
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testDesktopWidgets('default sidebar contains Auto without concrete models', (
    tester,
  ) async {
    final app = ModelWorkspaceFixture()..models.routingSettings = {};
    final preferences = UiPreferences()..setModelsExpanded(true);
    addTearDown(app.dispose);
    addTearDown(preferences.dispose);
    await tester.pumpWidget(
      AccountToolApp(application: app, preferences: preferences),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-models')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('model-nav-auto')), findsOneWidget);
    expect(find.text('暂无匹配模型'), findsNothing);
    expect(find.byKey(const Key('model-nav-MiniMax-M3')), findsNothing);
    expect(find.byKey(const Key('model-nav-deepseek-flash')), findsNothing);
  });
  testDesktopWidgets(
    'only official model names appear in model navigation and details',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = ModelWorkspaceFixture();
      final preferences = UiPreferences();
      addTearDown(app.dispose);
      addTearDown(preferences.dispose);
      final account = app.accounts.accounts.last;
      account.facts['provider'] = 'trae-cn';
      account.models.addAll([
        {
          'id': 'DeepSeek-V4-Flash-Official-max',
          'name': 'DeepSeek-V4-Flash (Max)',
        },
        {'id': 'native-only', 'name': 'Native Only'},
      ]);
      app.models.routingSettings = {
        'version': 2,
        'published': {'deepseek-v4-flash-(max)': true, 'native-only': true},
      };
      await tester.pumpWidget(
        AccountToolApp(application: app, preferences: preferences),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-models')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('show-all-models')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('model-nav-native-only')), findsNothing);
      expect(find.byKey(const Key('model-native-only')), findsNothing);
      expect(
        find.byKey(const Key('model-nav-deepseek-v4-flash-(max)')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('model-nav-deepseek-flash')));
      await tester.pumpAndSettle();
      final details = find.text('来源与额度详情').last;
      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.text('deepseek-flash').hitTestable(), findsWidgets);
      expect(find.text('额度尚无成功查询记录'), findsOneWidget);
      expect(find.text('DeepSeek-V4-Flash-Official-max'), findsNothing);
      expect(find.text('deepseek-v4.1-flash-1017'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [1280.0, 480.0]) {
    testDesktopWidgets(
      'catalog searches a native alias in the main area at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final app = ModelWorkspaceFixture();
        final preferences = UiPreferences();
        addTearDown(app.dispose);
        addTearDown(preferences.dispose);
        await tester.pumpWidget(
          AccountToolApp(application: app, preferences: preferences),
        );
        await tester.pumpAndSettle();
        Future<void> openNarrowNavigation() async {
          if (width == 480) {
            await tester.tap(find.byKey(const Key('toggle-sidebar')));
            await tester.pumpAndSettle();
          }
        }

        await openNarrowNavigation();
        await tester.tap(find.byKey(const Key('nav-models')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('model-nav-search')), findsNothing);
        await tester.enterText(find.byKey(const Key('model-search')), '1017');
        await tester.pumpAndSettle();
        final result = find.byKey(const Key('model-deepseek-flash'));
        expect(result, findsOneWidget);
        expect(find.byKey(const Key('model-MiniMax-M3')), findsNothing);
        await tester.tap(
          find.descendant(of: result, matching: find.text('deepseek-flash')),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<AppWorkspace>(find.byType(AppWorkspace))
              .selectedModelId,
          'deepseek-flash',
        );
        await tester.tap(find.text('全部模型').hitTestable());
        await tester.pumpAndSettle();
        final searchField = find.descendant(
          of: find.byKey(const Key('model-search')),
          matching: find.byType(EditableText),
        );
        expect(
          tester.widget<EditableText>(searchField).controller.text,
          '1017',
        );
        expect(result.hitTestable(), findsOneWidget);
        expect(find.byKey(const Key('model-MiniMax-M3')), findsNothing);
        await tester.tap(
          find.descendant(of: result, matching: find.text('deepseek-flash')),
        );
        await tester.pumpAndSettle();
        expect(app.accounts.refreshes, 0);
        app.models.routingSettings = {
          'version': 2,
          'published': {'MiniMax-M3': true},
        };
        await app.models.reorderModels(['MiniMax-M3', 'deepseek-flash']);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('model-nav-deepseek-flash')), findsNothing);
        expect(
          tester
              .widget<AppWorkspace>(find.byType(AppWorkspace))
              .selectedModelId,
          'deepseek-flash',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testDesktopWidgets(
    'root composition follows model order and opens the exact regional account',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = ModelWorkspaceFixture();
      final preferences = UiPreferences()..setModelsExpanded(true);
      addTearDown(app.dispose);
      addTearDown(preferences.dispose);
      await tester.pumpWidget(
        AccountToolApp(application: app, preferences: preferences),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-models')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('model-nav-auto')), findsOneWidget);
      await tester.tap(find.byKey(const Key('model-nav-deepseek-flash')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PluginModelServicesPage>(
              find.byType(PluginModelServicesPage),
            )
            .selectedModelId,
        'deepseek-flash',
      );
      expect(find.text('60 credits'), findsOneWidget);
      expect(find.text('48 credits'), findsOneWidget);
      expect(find.text('32.5 credits'), findsOneWidget);
      for (final (label, balance, region) in [
        ('日常账号 14', '60 credits', 'Qoder CN · cn'),
        ('海外账号', '48 credits', 'Qoder · global'),
      ]) {
        await tester.tap(find.text(label).hitTestable());
        await tester.pumpAndSettle();
        final detail = find.byKey(const Key('account-detail-page'));
        final sidebar = find.byKey(const Key('nav-overview'));
        expect(sidebar.hitTestable(), findsOneWidget);
        expect(
          tester.getRect(detail).left,
          greaterThanOrEqualTo(tester.getRect(sidebar).right),
        );
        expect(tester.getRect(detail).width, greaterThan(800));
        expect(find.text(label), findsOneWidget);
        expect(find.text(balance, findRichText: true), findsOneWidget);
        final profile = find.byKey(const Key('detail-profile'));
        await tester.ensureVisible(profile);
        await tester.tap(profile);
        await tester.pumpAndSettle();
        expect(find.text('user-13'), findsOneWidget);
        expect(find.text(region), findsOneWidget);
        final back = find.byKey(const Key('account-back'));
        await tester.tap(back);
        await tester.pumpAndSettle();
        await tester.tap(back);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('account-detail-page')), findsNothing);
        expect(
          find.byKey(const Key('model-published-deepseek-flash')),
          findsOneWidget,
        );
        expect(app.accounts.refreshes, 0);
      }

      await app.models.reorderModels(['deepseek-flash', 'MiniMax-M3']);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-models')));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const Key('model-nav-deepseek-flash'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const Key('model-nav-MiniMax-M3'))).dy,
        ),
      );
      await tester.tap(find.byKey(const Key('model-nav-auto')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AppWorkspace>(find.byType(AppWorkspace)).selectedModelId,
        'auto',
      );
      expect(find.text('模型顺序').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
