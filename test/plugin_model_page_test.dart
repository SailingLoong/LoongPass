import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
  Map get routingSettings => settings;
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
  test(
    'a saved Auto priority survives a restart and a rejected update',
    () async {
      final accounts = WorkspaceFixtureAccounts();
      final store = MemoryAccountStore('routing')
        ..data = {
          'version': 4,
          'routing': {
            'version': 2,
            'order': ['deepseek-flash', 'MiniMax-M3'],
          },
        };
      var service = PluginModelService(accounts: accounts, store: store);
      addTearDown(accounts.dispose);
      addTearDown(() => service.close());
      await service.start();
      final previousOrder = service.catalog.map((m) => m.id).toList();
      expect(
        AutoRoutingPriority.fromSettings(service.routingSettings),
        AutoRoutingPriority.modelOrder,
      );
      await service.setAutoRoutingPriority(AutoRoutingPriority.creditExpiry);
      await service.close();
      service = PluginModelService(accounts: accounts, store: store);
      await service.start();
      expect(
        AutoRoutingPriority.fromSettings(service.routingSettings),
        AutoRoutingPriority.creditExpiry,
      );
      expect(service.catalog.map((m) => m.id), previousOrder);
      store.beforeWrite = () async => throw StateError('fixture write failure');
      await expectLater(
        service.setAutoRoutingPriority(AutoRoutingPriority.modelOrder),
        throwsStateError,
      );
      expect(
        AutoRoutingPriority.fromSettings(service.routingSettings),
        AutoRoutingPriority.creditExpiry,
      );
    },
  );

  testDesktopWidgets(
    'switching Auto priority previews the spendable model and preserves its saved order',
    (tester) async {
      final app = ModelWorkspaceFixture();
      addTearDown(app.dispose);
      app.accounts.accounts
        ..clear()
        ..add(
          PluginAccount(
            key: 'sample',
            active: true,
            facts: {
              'provider': 'qoder',
              'registrationId': 'sample',
              'label': '甲账号',
            },
            models: [
              {'id': 'MiniMax-M3'},
              {'id': 'dfmodel'},
            ],
            usage: {
              'windows': [
                {
                  'models': ['dfmodel'],
                  'balance': 100,
                  'runsOut': 100,
                  'unit': 'credits',
                  'runsOutAt': DateTime.now()
                      .add(const Duration(days: 1))
                      .toIso8601String(),
                },
              ],
            },
          ),
        );
      await tester.pumpWidget(
        DesktopTestApp(
          home: Scaffold(
            body: PluginModelServicesPage(
              application: app,
              selectedModelId: 'auto',
            ),
          ),
        ),
      );
      final preview = find.byKey(const Key('auto-route-preview'));
      Finder inPreview(String value) =>
          find.descendant(of: preview, matching: find.textContaining(value));
      expect(inPreview('MiniMax-M3'), findsOneWidget);
      await tester.tap(find.text('积分到期优先').hitTestable());
      await tester.pumpAndSettle();
      expect(inPreview('deepseek-flash'), findsOneWidget);
      expect(inPreview('甲账号'), findsOneWidget);
      expect(inPreview('100 credits'), findsOneWidget);
      expect(app.models.catalog.map((model) => model.id), [
        'MiniMax-M3',
        'deepseek-flash',
      ]);
      await tester.tap(find.text('模型优先').hitTestable());
      await tester.pumpAndSettle();
      expect(inPreview('MiniMax-M3'), findsOneWidget);
      expect(app.accounts.refreshes, 0);
    },
  );

  testDesktopWidgets(
    'Auto can rank a native-only media candidate without publishing it as an official model',
    (tester) async {
      final app = ModelWorkspaceFixture();
      addTearDown(app.dispose);
      final account = app.accounts.accounts.first;
      account.models.add({
        'id': 'native-image-slot',
        'name': '渠道图像模型',
        'outputs': ['image'],
      });
      final candidate = app.models.catalog.singleWhere(
        (model) => !model.official,
      );
      final selected = <String?>[];
      await tester.pumpWidget(
        DesktopTestApp(
          home: Scaffold(
            body: PluginModelServicesPage(
              application: app,
              selectedModelId: 'auto',
              onSelectModel: selected.add,
            ),
          ),
        ),
      );
      final row = find.byKey(ValueKey('model-${candidate.id}'));
      expect(row, findsOneWidget);
      await tester.ensureVisible(find.text('渠道图像模型'));
      await tester.tap(find.text('渠道图像模型'));
      expect(selected, isEmpty);
      final up = find.bySemanticsLabel('上移 渠道图像模型');
      await tester.ensureVisible(up);
      await tester.tap(up);
      await tester.pumpAndSettle();
      final preview = find.byKey(const Key('auto-route-preview'));
      expect(
        find.descendant(of: preview, matching: find.textContaining('渠道图像模型')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: preview, matching: find.textContaining('图像生成')),
        findsOneWidget,
      );
      expect(
        app.connection.routing.groups.containsKey(candidate.groupId),
        isFalse,
      );
    },
  );

  testDesktopWidgets(
    'a native-only candidate removed by a catalog filter can rejoin at its saved rank',
    (tester) async {
      final accounts = WorkspaceFixtureAccounts();
      accounts.accounts.first.models.add({'id': 'native-slot', 'name': '渠道候选'});
      final service = PluginModelService(
        accounts: accounts,
        store: MemoryAccountStore('restore-auto'),
      );
      await service.start();
      final app = _Application(service);
      try {
        final catalog = service.catalog;
        final native = catalog.singleWhere((model) => !model.official);
        await service.reorderModels([
          native.id,
          ...catalog.where((m) => m.official).map((m) => m.id),
        ]);
        await tester.pumpWidget(
          DesktopTestApp(
            home: Scaffold(body: PluginModelServicesPage(application: app)),
          ),
        );
        final search = find.byKey(const Key('model-search'));
        await tester.enterText(search, 'MiniMax-M3');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('retain-models')));
        await tester.pumpAndSettle();
        expect(service.catalog.where((m) => m.enabled).single.id, 'MiniMax-M3');
        await tester.enterText(search, '');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('open-auto-routing')));
        await tester.pumpAndSettle();
        final excluded = find.text('未参与（2）');
        await tester.ensureVisible(excluded);
        await tester.tap(excluded);
        await tester.pumpAndSettle();
        expect(find.text('渠道候选').hitTestable(), findsOneWidget);
        await tester.enterText(search, '渠道候选');
        await tester.pumpAndSettle();
        final join = find.text('加入 Auto').hitTestable();
        await tester.ensureVisible(join);
        await tester.tap(join);
        await tester.pumpAndSettle();
        expect(service.catalog.first.id, native.id);
        expect(service.catalog.first.enabled, isTrue);
        expect(service.catalog.first.published, isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.connection.dispose();
        await service.close();
        accounts.dispose();
      }
    },
  );

  for (final brightness in Brightness.values) {
    testDesktopWidgets(
      'connection sheet paints an opaque full-height surface in ${brightness.name}',
      (tester) async {
        final service = _Service(), capture = GlobalKey();
        final app = _Application(service);
        addTearDown(service.dispose);
        addTearDown(app.connection.dispose);
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: DesktopTestApp(
              theme: loongPassTheme(brightness),
              home: Scaffold(body: PluginModelServicesPage(application: app)),
            ),
          ),
        );
        await tester.tap(find.text('连接设置'));
        await tester.pumpAndSettle();
        final colors = loongPassDesignTheme(brightness).colors;
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        await tester.runAsync(() async {
          final frame = await boundary.toImage();
          try {
            final rgba = (await frame.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            List<int> pixel(int x, int y) {
              final offset = 4 * (frame.width * y + x);
              return [for (var i = 0; i < 4; i++) rgba.getUint8(offset + i)];
            }

            List<int> opaque(Color color) {
              final rgb = color.toARGB32();
              return [(rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255, 255];
            }

            final left = frame.width - 462;
            for (final y in [1, frame.height ~/ 2, frame.height - 2]) {
              expect(pixel(left + 4, y), opaque(colors.background));
              expect(
                pixel(left, y),
                opaque(Color.alphaBlend(colors.border, colors.background)),
              );
            }
          } finally {
            frame.dispose();
          }
        });
      },
    );
  }
  testDesktopWidgets(
    'at 480px with large text Auto opens by keyboard and its controls stack above the preview',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(480, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final service = _Service(), app = _Application(service);
      addTearDown(service.dispose);
      addTearDown(app.connection.dispose);
      await tester.pumpWidget(
        DesktopTestApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(body: PluginModelServicesPage(application: app)),
        ),
      );
      final button = find.text('LoongPass Auto');
      Focus.of(tester.element(button)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const Key('auto-route-preview'))).top,
        greaterThan(tester.getRect(find.text('积分到期优先')).bottom),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testDesktopWidgets(
    'empty model sources can be inspected without starting a connection',
    (tester) async {
      final service = _Service()..grants.clear();
      final app = _Application(service);
      addTearDown(service.dispose);
      addTearDown(app.connection.dispose);
      await tester.pumpWidget(
        DesktopTestApp(
          home: Scaffold(body: PluginModelServicesPage(application: app)),
        ),
      );
      expect(find.text('暂无账号来源'), findsOneWidget);
      expect(find.text('连接设置'), findsOneWidget);
      expect(app.connection.checkedAt, isNull);
      expect(service.changes, 0);
    },
  );

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
        await tester.ensureVisible(find.byKey(const Key('show-all-models')));
        await tester.pumpAndSettle();
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
      const modelName = 'kimi-k2.7-code-highspeed';
      const accountName =
          'Long account name with an official source and a recognizable identity';
      service.grants.first.account.models
        ..clear()
        ..add({'id': modelName});
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
      await tester.ensureVisible(find.byKey(const Key('show-all-models')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('show-all-models')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(modelName));
      await tester.tap(find.text(modelName));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.text(accountName).first,
        find.byType(Scrollable).first,
        const Offset(0, -300),
      );
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
      await tester.ensureVisible(find.byKey(const Key('show-all-models')));
      await tester.pumpAndSettle();
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
      expect(find.text('仅赠送'), findsOneWidget);
      expect(find.text('赠送优先，可转套餐'), findsOneWidget);
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
      const name = 'kimi-k2.7-code-highspeed';
      service.grants.single.account.models.add({'id': name});
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
      await tester.ensureVisible(find.byKey(const Key('show-all-models')));
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
    expect(find.text('模型目录'), findsOneWidget);
    expect(
      tester.getSize(find.text('显示全部模型')).height,
      lessThanOrEqualTo(
        tester.getSize(find.byKey(const Key('model-search'))).height,
      ),
    );
    await tester.tap(find.byKey(const Key('open-auto-routing')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('model-published-deepseek-flash')),
      findsNothing,
    );
    await tester.enterText(find.byKey(const Key('model-search')), '1017');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('model-glm-5.3-flash')), findsNothing);
    expect(find.text('02'), findsOneWidget);
    final arrow = find.descendant(
      of: find.bySemanticsLabel('上移 deepseek-flash'),
      matching: find.byType(Icon),
    );
    Focus.of(tester.element(arrow)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(service.catalog.first.id, 'deepseek-flash');
    expect(service.changes, 1);
    expect(tester.takeException(), isNull);
  });

  testDesktopWidgets('connection sheet opens grants without writing settings', (
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
    expect(find.text('开放给 Magpie 的账号'), findsNothing);
    await tester.tap(find.text('连接设置'));
    await tester.pumpAndSettle();
    expect(find.text('开放给 Magpie 的账号'), findsOneWidget);
    expect(find.text('Demo account'), findsOneWidget);
    expect(service.changes, 0);
    await tester.tap(find.text('Demo account'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('关闭连接设置'));
    await tester.pumpAndSettle();
    expect(find.text('开放给 Magpie 的账号'), findsNothing);
    expect(service.changes, 1);
  });
}
