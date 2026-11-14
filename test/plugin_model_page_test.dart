import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/plugin_accounts.dart';
import '../lib/model_connection.dart';
import '../lib/plugin_application.dart';
import '../lib/plugin_model_service.dart';
import '../lib/plugin_model_page.dart';
import '../lib/app_theme.dart';
import 'desktop_test_app.dart';

class _Service extends ChangeNotifier implements PluginModelService {
  int changes = 0;
  void publish() => notifyListeners();
  @override
  bool get enabled => true;
  @override
  bool get running => true;
  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:3426');
  @override
  String? get error => null;
  @override
  final grants = [
    PluginModelGrant(
      PluginAccount(
        key: 'zcode#one',
        active: true,
        facts: {
          'provider': 'zcode',
          'uid': 'demo',
          'label': 'Demo account',
          'realm': 'bigmodel',
          'registrationId': 'one',
        },
        models: [
          for (var i = 1; i <= 20; i++)
            {
              'id': i == 20 ? 'GLM-Trial' : 'GLM-$i',
              'name': i == 20 ? 'GLM Trial' : 'GLM $i',
            },
        ],
      ),
      'synthetic',
      true,
    ),
  ];
  @override
  Future<void> enable(String key, bool enabled) async {
    changes++;
  }

  @override
  Future<void> setEnabled(bool value) async {
    changes++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Application implements PluginApplication {
  _Application(this.models) : connection = ModelConnection(models, '/bridge');
  @override
  final ModelConnection connection;
  @override
  final PluginModelService models;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testDesktopWidgets(
    'all upstream models and entitlement labels remain accessible without connecting',
    (tester) async {
      final service = _Service();
      final app = _Application(service);
      addTearDown(service.dispose);
      addTearDown(app.connection.dispose);
      await tester.pumpWidget(
        DesktopTestApp(
          home: Scaffold(body: PluginModelServicesPage(application: app)),
        ),
      );
      expect(find.text('GLM Trial · 仅赠送').hitTestable(), findsNothing);
      final expand = find.byKey(const Key('models-zcode#one'));
      await tester.scrollUntilVisible(expand, 250);
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看 20 个模型'));
      await tester.pumpAndSettle();
      service.publish();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('GLM Trial · 仅赠送'));
      await tester.pumpAndSettle();
      expect(find.text('GLM Trial · 仅赠送').hitTestable(), findsOneWidget);
      expect(find.text('GLM 1 · 赠送优先，可转套餐'), findsOneWidget);
      expect(service.changes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testDesktopWidgets(
    'long model names remain readable in a narrow large-text layout',
    (tester) async {
      tester.view.physicalSize = const Size(604, 632);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _Service();
      const name =
          'Long model name with native reasoning and tool support from the upstream catalog';
      service.grants.single.account.models.add({
        'id': 'long-model',
        'name': name,
      });
      final app = _Application(service);
      addTearDown(service.dispose);
      addTearDown(app.connection.dispose);
      await tester.pumpWidget(
        DesktopTestApp(
          theme: loongPassTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(body: PluginModelServicesPage(application: app)),
        ),
      );
      await tester.ensureVisible(find.text('查看 21 个模型'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看 21 个模型'));
      await tester.pumpAndSettle();
      service.publish();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('$name · 赠送优先，可转套餐'));
      await tester.pumpAndSettle();
      expect(find.text('$name · 赠送优先，可转套餐').hitTestable(), findsOneWidget);
      expect(service.changes, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
