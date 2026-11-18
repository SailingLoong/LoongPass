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
      await tester.tap(find.byKey(const Key('nav-models')));
      await tester.pumpAndSettle();
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
      expect(find.textContaining('loongpass/auto').hitTestable(), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
