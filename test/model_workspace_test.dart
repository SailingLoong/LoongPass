import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/app_sidebar.dart';
import '../lib/main.dart';
import '../lib/plugin_model_page.dart';
import '../lib/ui_preferences.dart';
import 'desktop_test_app.dart';
import 'model_workspace_fixture.dart';

void main() {
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
    testDesktopWidgets('sidebar searches native aliases at width $width', (
      tester,
    ) async {
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
      await openNarrowNavigation();
      await tester.enterText(find.byKey(const Key('model-nav-search')), '1017');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('model-nav-deepseek-flash')), findsOneWidget);
      expect(find.byKey(const Key('model-nav-MiniMax-M3')), findsNothing);
      await tester.tap(find.byKey(const Key('model-nav-deepseek-flash')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AppWorkspace>(find.byType(AppWorkspace)).selectedModelId,
        'deepseek-flash',
      );
      expect(app.accounts.refreshes, 0);
      app.models.routingSettings = {
        'version': 2,
        'published': {'MiniMax-M3': true},
      };
      await app.models.reorderModels(['MiniMax-M3', 'deepseek-flash']);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('model-nav-deepseek-flash')), findsNothing);
      expect(
        tester.widget<AppWorkspace>(find.byType(AppWorkspace)).selectedModelId,
        'deepseek-flash',
      );
      expect(tester.takeException(), isNull);
    });
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
      await tester.tap(find.text('日常账号 14').hitTestable());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('account-qoderCn/saved-13')).hitTestable(),
        findsOneWidget,
      );
      final selected = find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.selected == true,
      );
      expect(
        find.ancestor(
          of: find.byKey(const Key('account-qoderCn/saved-13')),
          matching: selected,
        ),
        findsOneWidget,
      );
      expect(app.accounts.refreshes, 0);

      expect(preferences.appsExpanded, isTrue);
      expect(preferences.modelsExpanded, isFalse);
      await tester.tap(find.byKey(const Key('nav-models')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('model-nav-deepseek-flash')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('海外账号').hitTestable());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('account-qoder/global-13')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.byKey(const Key('account-qoder/global-13')),
          matching: selected,
        ),
        findsOneWidget,
      );

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
      expect(find.text('候选顺序').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
