import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/plugin_accounts.dart';
import '../lib/model_connection.dart';
import '../lib/plugin_application.dart';
import '../lib/plugin_model_service.dart';
import '../lib/plugin_model_catalog.dart';
import '../lib/plugin_model_page.dart';
import '../lib/app_theme.dart';
import 'desktop_test_app.dart';
import 'memory_account_store.dart';
import 'model_workspace_fixture.dart';

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
          {'id': 'GLM-5.3-Flash', 'name': 'GLM-5.3-Flash'},
          {'id': 'GLM-5.3-Flash-Trial', 'name': 'GLM-5.3-Flash Trial'},
          {'id': 'deepseek-v4.1-flash-1017', 'name': 'DeepSeek Flash'},
        ],
      ),
      'synthetic',
      true,
    ),
  ];
  Map<String, dynamic> settings = {};
  @override
  List<PluginModel> get catalog =>
      pluginModelCatalog(grants, settings, DateTime.now());
  @override
  Future<void> setModelAccountEnabled(
    String id,
    String account,
    bool value,
  ) async {
    changes++;
    settings['accounts'] = {
      id: {account: value},
    };
    publish();
  }

  @override
  Future<void> setModelEnabled(String id, bool value) async {
    changes++;
    settings['models'] = {id: value};
    publish();
  }

  @override
  Future<void> reorderModels(List<String> order) async {
    changes++;
    settings['order'] = order;
    publish();
  }

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
    'concrete models start hidden until searched and explicitly published',
    (tester) async {
      final service = PluginModelService(
        accounts: WorkspaceFixtureAccounts(),
        store: MemoryAccountStore('publication-ui'),
      );
      await service.start();
      final app = _Application(service);
      try {
        await tester.pumpWidget(
          DesktopTestApp(
            home: Scaffold(body: PluginModelServicesPage(application: app)),
          ),
        );
        expect(find.text('MiniMax-M3'), findsNothing);
        await tester.enterText(
          find.byKey(const Key('model-search')),
          'MiniMax',
        );
        await tester.pumpAndSettle();
        expect(find.text('MiniMax-M3'), findsOneWidget);
        await tester.tap(find.byKey(const Key('model-published-MiniMax-M3')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('model-search')), '');
        await tester.pumpAndSettle();
        expect(find.text('MiniMax-M3'), findsOneWidget);
        expect(service.catalog.every((model) => model.enabled), isTrue);
        await tester.tap(find.byKey(const Key('model-published-MiniMax-M3')));
        await tester.pumpAndSettle();
        expect(find.text('MiniMax-M3'), findsNothing);
        expect(service.catalog.every((model) => model.enabled), isTrue);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.connection.dispose();
        await service.close();
        service.accounts.dispose();
      }
    },
  );

  testDesktopWidgets(
    'filtered selection is saved and hidden models can be restored',
    (tester) async {
      final accounts = WorkspaceFixtureAccounts();
      final service = PluginModelService(
        accounts: accounts,
        store: MemoryAccountStore('ui-selection'),
      );
      await service.start();
      final app = _Application(service);
      try {
        await tester.pumpWidget(
          DesktopTestApp(
            home: Scaffold(body: PluginModelServicesPage(application: app)),
          ),
        );
        await tester.enterText(find.byKey(const Key('model-search')), '1017');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('retain-models')));
        await tester.pumpAndSettle();
        expect(service.catalog.where((m) => m.enabled).map((m) => m.id), [
          'deepseek-flash',
        ]);
        await tester.enterText(find.byKey(const Key('model-search')), '');
        await tester.pumpAndSettle();
        expect(find.text('MiniMax-M3'), findsNothing);
        await tester.tap(find.byKey(const Key('show-all-models')));
        await tester.pumpAndSettle();
        expect(find.text('MiniMax-M3'), findsOneWidget);
        await tester.tap(find.text('MiniMax-M3'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('参与 Auto'));
        await tester.pumpAndSettle();
        expect(service.catalog.every((m) => m.enabled), isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.connection.dispose();
        await service.close();
        accounts.dispose();
      }
    },
  );
  testDesktopWidgets(
    'long model and account names fit a narrow window at 200 percent text scale',
    (tester) async {
      tester.view.physicalSize = const Size(604, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _Service();
      const modelName =
          'Long model name with native reasoning and tool support from the upstream catalog';
      const accountName =
          'Long account name with an official source and a recognizable identity';
      service.grants.first.account.models
        ..clear()
        ..add({'id': 'long-model', 'name': modelName});
      service.grants.first.account.facts['label'] = accountName;
      final app = _Application(service);
      addTearDown(service.dispose);
      addTearDown(app.connection.dispose);
      await tester.pumpWidget(
        DesktopTestApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: PluginModelServicesPage(
              application: app,
              onOpenAccount: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('show-all-models')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(modelName));
      await tester.tap(find.text(modelName));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(accountName).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testDesktopWidgets(
    'canonical list searches aliases and preserves account identity',
    (tester) async {
      final service = _Service();
      final app = _Application(service);
      PluginAccount? opened;
      addTearDown(service.dispose);
      addTearDown(app.connection.dispose);
      await tester.pumpWidget(
        DesktopTestApp(
          home: Scaffold(
            body: PluginModelServicesPage(
              application: app,
              onOpenAccount: (a) => opened = a,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('show-all-models')));
      await tester.pumpAndSettle();
      expect(find.text('glm-5.3-flash'), findsOneWidget);
      expect(find.text('deepseek-flash'), findsOneWidget);
      expect(service.changes, 0);
      await tester.enterText(find.byKey(const Key('model-search')), '1017');
      await tester.pumpAndSettle();
      expect(find.text('glm-5.3-flash'), findsNothing);
      expect(find.text('deepseek-flash'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('model-search')), '');
      await tester.pumpAndSettle();
      await tester.tap(find.text('glm-5.3-flash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('来源与额度详情'));
      await tester.pumpAndSettle();
      expect(find.text('GLM-5.3-Flash-Trial · 仅赠送'), findsOneWidget);
      expect(find.text('GLM-5.3-Flash · 赠送优先，可转套餐'), findsOneWidget);
      service.publish();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Demo account').hitTestable());
      expect(identical(opened, service.grants.first.account), isTrue);
      expect(service.changes, 0);
      final semantics = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel(RegExp('参与此模型路由 Demo account')),
        findsWidgets,
      );
      semantics.dispose();
      await tester.tap(find.byKey(const ValueKey('model-account-zcode#one')));
      await tester.pumpAndSettle();
      expect(service.catalog.first.bindings.every((b) => !b.enabled), isTrue);
      expect(service.catalog.last.bindings.every((b) => b.enabled), isTrue);
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
      service.publish();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('show-all-models')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(name));
      await tester.pumpAndSettle();
      expect(find.text(name).hitTestable(), findsOneWidget);
      expect(service.changes, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testDesktopWidgets('model priority changes by keyboard-accessible action', (
    tester,
  ) async {
    final service = _Service();
    final app = _Application(service);
    addTearDown(service.dispose);
    addTearDown(app.connection.dispose);
    await tester.pumpWidget(
      DesktopTestApp(
        home: Scaffold(body: PluginModelServicesPage(application: app)),
      ),
    );
    await tester.tap(find.byKey(const Key('show-all-models')));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('上移 deepseek-flash'));
    await tester.pumpAndSettle();
    expect(service.catalog.first.id, 'deepseek-flash');
    expect(service.changes, 1);
    expect(tester.takeException(), isNull);
  });
}
