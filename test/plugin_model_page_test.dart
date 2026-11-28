import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/plugin_accounts.dart';
import '../lib/model_connection.dart';
import '../lib/plugin_application.dart';
import '../lib/plugin_model_accounts.dart';
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
  bool catalogReady = true;
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
  Map<String, dynamic> settings = {'version': 4};
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
  Future<void> enableRegistrations(
    Set<AccountRegistration> registrations,
    bool enabled,
  ) async {
    changes++;
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
  for (final width in [480.0, 1080.0]) {
    testDesktopWidgets(
      'open a Loomy model source from its row at width $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 850);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final loomy = PluginAccount(
          key: 'loomy#demo',
          facts: {
            'provider': 'loomy',
            'label': 'Loomy 测试账号',
            'registrationId': 'loomy-registration',
          },
          active: true,
          models: [
            {'id': 'deepseek-flash'},
            {'id': 'glm-5.3-flash'},
          ],
        );
        final accounts = WorkspaceFixtureAccounts()
          ..accounts.removeWhere((a) => a.provider != 'qoder')
          ..accounts.add(loomy);
        final store = MemoryAccountStore('model-access');
        var service = PluginModelService(accounts: accounts, store: store);
        await service.start();
        await service.setModelPublished('deepseek-flash', true);
        await service.setModelPublished('glm-5.3-flash', true);
        final app = _Application(service);
        try {
          await tester.pumpWidget(
            DesktopTestApp(
              home: Scaffold(
                body: PluginModelServicesPage(
                  application: app,
                  selectedModelId: 'deepseek-flash',
                ),
              ),
            ),
          );
          expect(find.text(loomy.label), findsNothing);
          final plan = find.byKey(ValueKey(loomy.plan));
          await tester.ensureVisible(plan);
          await tester.tap(plan);
          await tester.pumpAndSettle();
          expect(find.text('海外账号'), findsNothing);
          final open = find.bySemanticsLabel('向本机模型服务开放 ${loomy.label}');
          final participate = find.byKey(
            ValueKey('model-account-${loomy.key}'),
          );
          final rowError = find.descendant(
            of: find.byType(PluginModelAccounts),
            matching: find.text('设置保存失败，请重试。'),
          );
          expect(participate, findsNothing);
          await tester.ensureVisible(open);
          expect(open.hitTestable(), findsOneWidget);
          store.beforeWrite = () async => throw StateError('write rejected');
          await tester.tap(open);
          await tester.pumpAndSettle();
          expect(rowError, findsOneWidget);
          expect(service.grants.any((g) => g.enabled), isFalse);
          expect(participate, findsNothing);
          store.beforeWrite = null;
          await tester.tap(open);
          await tester.pumpAndSettle();
          expect(open, findsNothing);
          expect(rowError, findsNothing);
          expect(
            service.grants.singleWhere((g) => g.enabled).account.key,
            loomy.key,
          );
          expect(
            service.catalog.every((m) => m.preferred?.account.key == loomy.key),
            isTrue,
          );
          await tester.ensureVisible(participate);
          await tester.tap(participate);
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox.shrink());
          await service.close();
          service = PluginModelService(accounts: accounts, store: store);
          await service.start();
          expect(
            service.grants.singleWhere((g) => g.enabled).account.key,
            loomy.key,
          );
          expect(
            service.catalog
                .singleWhere((m) => m.id == 'deepseek-flash')
                .preferred,
            isNull,
          );
          expect(
            service.catalog
                .singleWhere((m) => m.id == 'glm-5.3-flash')
                .preferred
                ?.account
                .key,
            loomy.key,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          app.connection.dispose();
          await service.close();
          accounts.dispose();
        }
      },
    );
  }

  testDesktopWidgets('expired platform access leads to the affected account', (
    tester,
  ) async {
    final service = _Service();
    final saved = service.grants.single.account;
    final expired = PluginAccount(
      key: saved.key,
      facts: saved.facts,
      active: true,
      models: saved.models,
      error: 'authorization_required',
    );
    service.grants[0] = PluginModelGrant(expired, 'synthetic', true);
    final app = _Application(service);
    PluginAccount? opened;
    addTearDown(service.dispose);
    addTearDown(app.connection.dispose);
    await tester.pumpWidget(
      DesktopTestApp(
        home: Scaffold(
          body: PluginModelServicesPage(
            application: app,
            selectedModelId: 'deepseek-flash',
            onOpenAccount: (a) => opened = a,
          ),
        ),
      ),
    );
    final plan = find.byKey(ValueKey(saved.plan));
    await tester.ensureVisible(plan);
    await tester.tap(plan);
    await tester.pumpAndSettle();
    expect(find.text('平台账号需重新授权'), findsOneWidget);
    expect(find.text('开放账号'), findsNothing);
    expect(find.byKey(ValueKey('model-account-${saved.key}')), findsNothing);
    final account = find.text('查看账号');
    await tester.ensureVisible(account);
    await tester.tap(account);
    expect(opened, same(expired));
    expect(service.changes, 0);
  });

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
      expect(inPreview('甲账号'), findsNothing);
      expect(inPreview('套餐待核实'), findsOneWidget);
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

  testDesktopWidgets('Auto shows only published official models in order', (
    tester,
  ) async {
    final app = ModelWorkspaceFixture();
    addTearDown(app.dispose);
    app.accounts.accounts.first.models.add({
      'id': 'image-slot',
      'name': '渠道图像模型',
    });
    app.models.routingSettings = {
      'version': 3,
      'order': ['image-slot', 'deepseek-flash', 'MiniMax-M3'],
      'models': {
        'image-slot': true,
        'MiniMax-M3': true,
        'deepseek-flash': false,
      },
      'published': {'deepseek-flash': true},
    };
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
    expect(find.byKey(const Key('model-deepseek-flash')), findsOneWidget);
    expect(find.text('01'), findsOneWidget);
    expect(find.text('渠道图像模型'), findsNothing);
    expect(find.byKey(const Key('model-MiniMax-M3')), findsNothing);
    expect(find.text('加入 Auto'), findsNothing);
    await tester.tap(find.byKey(const Key('open-model-deepseek-flash')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('model-published-deepseek-flash')),
      findsOneWidget,
    );
    expect(find.text('参与 Auto'), findsNothing);
  });

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
      expect(find.text('尚未连接应用'), findsOneWidget);
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
        expect(
          service.catalog.where((m) => m.published).single.id,
          'MiniMax-M3',
        );
        await tester.tap(find.byKey(const Key('model-published-MiniMax-M3')));
        await tester.pumpAndSettle();
        expect(find.text('MiniMax-M3'), findsNothing);
        expect(service.catalog.any((model) => model.published), isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.connection.dispose();
        await service.close();
        service.accounts.dispose();
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
      final plan = find.byKey(ValueKey(service.grants.first.account.plan));
      await tester.ensureVisible(plan);
      await tester.tap(plan);
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
      final plan = find.byKey(ValueKey(service.grants.first.account.plan));
      await tester.ensureVisible(plan);
      await tester.tap(plan);
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
    final grants = find.text('应用与套餐（1）');
    expect(grants, findsNothing);
    await tester.tap(find.text('连接设置'));
    await tester.pumpAndSettle();
    expect(grants, findsOneWidget);
    expect(find.text('Demo account').hitTestable(), findsNothing);
    await tester.ensureVisible(grants);
    await tester.tap(grants);
    await tester.pumpAndSettle();
    final account = find.text('ZCode · 智谱 BigModel · 套餐待核实');
    expect(find.text('Demo account'), findsNothing);
    await tester.ensureVisible(account);
    expect(account.hitTestable(), findsOneWidget);
    expect(service.changes, 0);
    await tester.tap(account);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('关闭连接设置'));
    await tester.pumpAndSettle();
    expect(grants, findsNothing);
    expect(service.changes, 1);
  });
}
