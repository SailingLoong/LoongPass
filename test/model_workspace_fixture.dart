import 'package:flutter/foundation.dart';

import '../lib/model_connection.dart';
import '../lib/plugin_accounts.dart';
import '../lib/plugin_application.dart';
import '../lib/plugin_model_catalog.dart';
import '../lib/plugin_model_service.dart';
import '../lib/plugin_rewards.dart';

/// Synthetic owners for exercising the application's normal composition.
class ModelWorkspaceFixture implements PluginApplication {
  ModelWorkspaceFixture() {
    accounts = WorkspaceFixtureAccounts();
    rewards = PluginRewards(accounts, timers: false);
    models = WorkspaceFixtureModels(accounts);
    connection = ModelConnection(models, '/synthetic/bridge');
  }

  @override
  late final WorkspaceFixtureAccounts accounts;
  @override
  late final WorkspaceFixtureModels models;
  @override
  late final ModelConnection connection;
  @override
  late final PluginRewards rewards;

  void dispose() {
    rewards.close();
    connection.dispose();
    models.dispose();
    accounts.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class WorkspaceFixtureAccounts extends ChangeNotifier
    implements PluginAccounts {
  @override
  final providers = <String, Map<String, dynamic>>{};
  @override
  Set<String> get enabledProviders => {'qoder-cn', 'qoder'};
  @override
  String? get error => null;
  int refreshes = 0;
  @override
  Future<void> refresh() async => refreshes++;

  @override
  final accounts = [
    for (var i = 0; i < 14; i++)
      PluginAccount(
        key: 'saved-$i',
        facts: {
          'provider': 'qoder-cn',
          'uid': 'user-$i',
          'label': '日常账号 ${i + 1}',
          'realm': 'cn',
          'registrationId': 'registration-$i',
        },
        active: true,
        models: [
          {'id': i == 13 ? 'deepseek-v4.1-flash-1017' : 'MiniMax-M3'},
        ],
        usage: {
          'windows': [
            {
              'balance': 60,
              'unit': 'credits',
              'runsOut': 32.5,
              'runsOutAt': DateTime.now()
                  .add(const Duration(days: 1))
                  .toIso8601String(),
            },
          ],
        },
        queriedAt: DateTime.now(),
      ),
    PluginAccount(
      key: 'global-13',
      facts: {
        'provider': 'qoder',
        'uid': 'user-13',
        'label': '海外账号',
        'realm': 'global',
        'registrationId': 'global-registration',
      },
      active: true,
      models: [
        {'id': 'deepseek-flash'},
      ],
      usage: {
        'windows': [
          {'balance': 48, 'unit': 'credits'},
        ],
      },
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class WorkspaceFixtureModels extends ChangeNotifier
    implements PluginModelService {
  WorkspaceFixtureModels(this.accounts);
  final WorkspaceFixtureAccounts accounts;
  @override
  bool get enabled => true;
  @override
  bool get running => true;
  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:3426');
  @override
  String? get error => null;
  @override
  bool get routingConnected => false;
  @override
  Map<String, dynamic> routingSettings = {
    'version': 2,
    'published': {'MiniMax-M3': true, 'deepseek-flash': true},
  };
  @override
  List<PluginModelGrant> get grants => [
    for (final account in accounts.accounts)
      PluginModelGrant(account, 'synthetic', true),
  ];
  @override
  List<PluginModel> get catalog =>
      pluginModelCatalog(grants, routingSettings, DateTime.now());

  @override
  Future<void> setAutoRoutingPriority(AutoRoutingPriority priority) async {
    routingSettings = upgradeModelRouting(routingSettings);
    priority.saveTo(routingSettings);
    notifyListeners();
  }

  @override
  Future<void> reorderModels(List<String> order) async {
    routingSettings = {...routingSettings, 'order': order};
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
