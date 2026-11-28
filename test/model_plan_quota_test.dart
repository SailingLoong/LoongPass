import 'package:flutter_test/flutter_test.dart';

import '../lib/model_plan_quota.dart';
import '../lib/plugin_accounts.dart';
import '../lib/plugin_model_catalog.dart';
import '../lib/plugin_model_quota.dart';

void main() {
  final now = DateTime.utc(2026, 11, 28);
  PluginModelBinding binding(
    String uid,
    List<Map<String, dynamic>> windows, {
    String plan = 'Pro',
    bool granted = true,
    String realm = 'cn',
    String? key,
  }) {
    final usage = {'plan': plan, 'windows': windows};
    final account = PluginAccount(
      key: key ?? uid,
      facts: {
        'provider': 'workbuddy',
        'uid': uid,
        'realm': realm,
        'registrationId': uid,
      },
      active: true,
      models: const [],
      usage: usage,
    );
    return PluginModelBinding(
      PluginModelGrant(account, 'fixture', granted),
      {'id': 'chat', 'rate': 1},
      true,
      pluginModelQuota(usage, 'chat', now),
    );
  }

  Map<String, dynamic> credit(num amount, {String unit = 'credits'}) => {
    'walletScope': 'account',
    'name': 'Credits',
    'balance': amount,
    'unit': unit,
  };
  test('only eligible independent wallets count once per model and unit', () {
    final one = binding('one', [
      credit(640.25),
      {...credit(90), 'aside': true},
    ]);
    final two = binding('two', [credit(359.75), credit(2, unit: 'USD')]);
    final partial = binding('unknown', []);
    final quota = modelPlanQuota([
      one,
      two,
      one,
      binding('one', [credit(640.25)], key: 'alias'),
      partial,
      binding('waiting', [credit(360)], granted: false),
    ], now);
    expect(
      quota.amounts[(name: 'Credits', unit: 'credits', reset: '', span: null)],
      1000.0,
    );
    expect(
      quota.amounts[(name: 'Credits', unit: 'USD', reset: '', span: null)],
      2,
    );
    expect(quota.partial, isTrue);
    final team = modelPlanQuota([
      binding('one', [
        {...credit(50), 'walletScope': 'shared'},
      ], plan: 'Enterprise'),
      binding('two', [
        {...credit(50), 'walletScope': 'shared'},
      ], plan: 'Enterprise'),
    ], now);
    expect(team.shared, isTrue);
    expect(team.amounts, isEmpty);
    expect(
      one.account.plan,
      isNot(binding('one', [], realm: 'global').account.plan),
    );
  });
  test('different reset windows remain separate and expired observations cannot add capacity', () {
    final quota = modelPlanQuota([
      binding('one', [
        {...credit(36, unit: 'requests'), 'resetsAt': '2026-11-29T00:00:00Z'},
      ]),
      binding('two', [
        {...credit(180, unit: 'requests'), 'resetsAt': '2026-12-04T00:00:00Z'},
      ]),
      binding('old', [
        {...credit(999, unit: 'requests'), 'resetsAt': '2026-11-26T00:00:00Z'},
      ]),
    ], now);
    expect(quota.amounts.values, unorderedEquals([36, 180]));
    expect(quota.partial, isTrue);
  });
  test('one login contributes independent model-scoped entitlements to their official plans', () {
    final b = binding('one', [
      {
        ...credit(75),
        'plan': 'Gift',
        'models': ['chat'],
      },
      {
        ...credit(200, unit: 'requests'),
        'plan': 'Coding',
        'models': ['chat'],
      },
      {
        ...credit(999),
        'plan': 'Other',
        'models': ['image'],
      },
    ]);
    final groups = modelPlans(PluginModel('chat', 'chat', true, [b]));
    expect(groups.keys.map((p) => p.name), unorderedEquals(['Gift', 'Coding']));
    final gift = groups.entries.singleWhere((e) => e.key.name == 'Gift');
    final coding = groups.entries.singleWhere((e) => e.key.name == 'Coding');
    expect(modelPlanQuota(gift.value, now).amounts.values.single, 75);
    expect(modelPlanQuota(coding.value, now).amounts.values.single, 200);
    expect(
      modelPlanQuota(coding.value, now).amounts.keys.single.unit,
      'requests',
    );
  });
}
