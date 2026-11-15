import 'package:flutter_test/flutter_test.dart';

import '../lib/plugin_accounts.dart';
import '../lib/plugin_model_catalog.dart';
import '../lib/model_names.dart';
import '../lib/plugin_model_quota.dart';

final now = DateTime.utc(2026, 11, 15, 2);

PluginModelGrant grant(
  String key,
  String provider,
  List<Map<String, dynamic>> models, {
  List<Map<String, dynamic>> windows = const [],
  bool enabled = true,
  String? error,
}) => PluginModelGrant(
  PluginAccount(
    key: key,
    facts: {'provider': provider, 'label': key, 'registrationId': key},
    active: true,
    models: models,
    usage: {'windows': windows},
    error: error,
  ),
  'synthetic',
  enabled,
);

void main() {
  test('renewable refused windows recover at reset while expired credits stay unavailable', () {
    final reset = now.add(const Duration(minutes: 1));
    final window = {
      'name': 'WorkBuddy token window',
      'models': ['deepseek-flash'],
      'used': 100,
      'amount': 2000000,
      'limit': 2000000,
      'unit': 'tokens',
      'refused': true,
      'resetsAt': reset.toIso8601String(),
    };
    final usage = {
      'windows': [window],
    };
    expect(
      pluginModelQuota(usage, 'deepseek-flash', now).status,
      ModelQuotaStatus.exhausted,
    );
    expect(
      pluginModelQuota(usage, 'deepseek-flash', reset).status,
      ModelQuotaStatus.unknown,
    );
    expect(
      pluginModelQuota(
        usage,
        'deepseek-flash',
        reset.add(const Duration(seconds: 1)),
      ).status,
      ModelQuotaStatus.unknown,
    );
    expect(
      pluginModelQuota(
        {
          'windows': [
            {...window, 'balance': 0},
          ],
        },
        'deepseek-flash',
        reset,
      ).status,
      ModelQuotaStatus.unknown,
    );
    expect(
      pluginModelQuota(
        {
          'windows': [
            {
              ...window,
              'balance': 12.25,
              'used': 0,
              'runsOut': 12.25,
              'runsOutAt': reset.toIso8601String(),
            },
          ],
        },
        'deepseek-flash',
        reset,
      ).status,
      ModelQuotaStatus.expired,
    );
  });

  test('model windows match native sized IDs and allowlist precedence', () {
    const sized = {
      'models': ['model@256k'],
    };
    expect(modelWindowApplies(sized, 'MODEL@256K'), isTrue);
    expect(modelWindowApplies(sized, 'model'), isTrue);
    expect(modelWindowApplies(sized, 'model@500k'), isFalse);
    expect(
      modelWindowApplies({
        'models': ['model'],
      }, 'model@500k'),
      isTrue,
    );
    expect(
      modelWindowApplies({
        'models': ['model'],
        'notModels': ['model'],
      }, 'model'),
      isTrue,
    );
    expect(
      modelWindowApplies({
        'notModels': ['model@256k'],
      }, 'model@500k'),
      isTrue,
    );
    expect(
      modelWindowApplies({
        'notModels': ['model@256k'],
      }, 'model'),
      isFalse,
    );
    expect(
      modelWindowApplies({'model': 'other', ...sized}, 'model@256k'),
      isFalse,
    );
  });

  test(
    'freeFirst narrows explicit paid allowlists and drops empty windows',
    () {
      const model = 'GLM-5.3-Flash', trial = '$model-Trial';
      final usage = modelRoutingUsage(
        'zcode',
        [
          {'id': model},
          {'id': trial},
          {'id': 'GLM-5.2'},
        ],
        {
          'windows': [
            {
              'name': 'paid only',
              'models': [model],
              'used': 100,
            },
            {
              'name': 'shared paid',
              'models': [model, 'GLM-5.2'],
              'used': 100,
            },
            {
              'name': 'gift',
              'models': [trial],
              'balance': 12.25,
              'unit': 'credits',
            },
          ],
        },
        now,
      )!;
      final windows = (usage['windows'] as List).cast<Map>();
      expect(windows.map((w) => w['name']), ['shared paid', 'gift']);
      expect(windows.first['models'], ['GLM-5.2']);
      expect((windows.last['models'] as List).toSet(), {trial, model});
      expect(
        pluginModelQuota(usage, model, now).status,
        ModelQuotaStatus.available,
      );
      expect(
        pluginModelQuota(usage, 'GLM-5.2', now).status,
        ModelQuotaStatus.exhausted,
      );
    },
  );

  test('confirmed expired authorization excludes a positive cached balance while a failed usage query retains it', () {
    final catalog = pluginModelCatalog(
      [
        grant(
          'expired',
          'qoder',
          [
            {'id': 'dfmodel'},
          ],
          error: 'authorization_required',
          windows: [
            {
              'balance': 12.25,
              'unit': 'credits',
              'runsOutAt': '2026-11-15T03:00:00Z',
              'runsOut': 12.25,
            },
          ],
        ),
        grant(
          'cached',
          'qoder',
          [
            {'id': 'dfmodel'},
          ],
          error: 'usage_unavailable',
          windows: [
            {
              'balance': 10.0625,
              'unit': 'credits',
              'runsOutAt': '2026-11-16T03:00:00Z',
              'runsOut': 10.0625,
            },
          ],
        ),
      ],
      {},
      now,
    );
    expect(catalog.single.preferred!.account.key, 'cached');
    expect(catalog.single.availableAccounts, 1);
    final expired = catalog.single.bindings.singleWhere(
      (b) => b.account.key == 'expired',
    );
    expect(expired.account.active, isTrue);
    expect(expired.grant.authorizationRequired, isTrue);
    expect(expired.available, isFalse);
    expect(expired.expiry!.amount!.amount, 12.25);
    expect(expired.expiry!.amount!.unit, 'credits');
  });
  test(
    'official API names group known channel context and snapshot aliases only',
    () {
      for (final entry in <(String, String, String)>[
        ('workbuddy', 'claude-opus-5.5', 'claude-opus-5-5'),
        ('workbuddy', 'claude-opus-4.8-1m', 'claude-opus-4-8'),
        ('trae', 'gemini-3.1-pro-max', 'gemini-3.1-pro-preview'),
        ('trae', 'gpt-5.4-max', 'gpt-5.4'),
        ('minimax-code', 'MiniMax-M3.1-Flash-Preview', 'MiniMax-M3.1-Flash'),
        ('loomy', 'Kimi-k2.6', 'kimi-k2.6'),
      ]) {
        expect(officialModelId(entry.$1, {'id': entry.$2}), entry.$3);
      }
      expect(
        officialModelId('qoder', {'id': 'ultimate', 'name': 'Ultimate'}),
        isNull,
      );
      expect(officialModelId('other', {'id': 'dfmodel'}), isNull);
      expect(officialModelId('trae', {'id': 'gpt-5.4-unverified'}), isNull);
    },
  );
  test('ZCode ordinary freeFirst model uses a live gift expiry and keeps its paid fallback', () {
    final models = pluginModelCatalog(
      [
        grant(
          'z',
          'zcode',
          [
            {'id': 'GLM-5.3-Flash'},
            {'id': 'GLM-5.3-Flash-Trial'},
          ],
          windows: [
            {
              'name': 'Coding',
              'used': 100,
              'notModels': ['GLM-5.3-Flash-Trial'],
            },
            {
              'name': 'Gift',
              'models': ['GLM-5.3-Flash-Trial'],
              'used': 25,
              'amount': 250,
              'limit': 1000,
              'runsOut': 750,
              'runsOutAt': '2026-11-16T02:00:00Z',
            },
          ],
        ),
      ],
      const {},
      now,
    );
    final ordinary = models.single.bindings.singleWhere((b) => !b.giftOnly);
    expect(ordinary.available, isTrue);
    expect(ordinary.expiry!.at, DateTime.utc(2026, 11, 16, 2));
    expect(
      ordinary.expiry!.amount,
      isNull,
      reason: 'The supplier did not declare the gift unit.',
    );
  });
  test(
    'channel aliases share the official model while preserving native identity',
    () {
      final models = pluginModelCatalog(
        [
          grant('a', 'workbuddy', [
            {'id': 'deepseek-v4.1-flash', 'name': 'DeepSeek V4.1 Flash'},
          ]),
          grant('b', 'qoder', [
            {'id': 'dfmodel', 'name': 'DeepSeek-Flash'},
          ]),
          grant('c', 'zcode', [
            {'id': 'GLM-5.3-Flash-Trial', 'name': 'GLM 5.3 Flash Trial'},
          ]),
        ],
        const {},
        now,
      );
      final flash = models.singleWhere((m) => m.id == 'deepseek-flash');
      expect(flash.bindings.map((b) => b.nativeId), [
        'deepseek-v4.1-flash',
        'dfmodel',
      ]);
      expect(flash.bindings.map((b) => b.account.key), ['a', 'b']);
      expect(
        models
            .singleWhere((m) => m.id == 'glm-5.3-flash')
            .bindings
            .single
            .giftOnly,
        isTrue,
      );
    },
  );

  test('routing expires applicable remaining quota, excluding another model and renewal dates', () {
    final models = pluginModelCatalog(
      [
        grant(
          'later',
          'qoder',
          [
            {'id': 'dfmodel', 'name': 'DeepSeek-Flash'},
          ],
          windows: [
            {
              'models': ['dmodel'],
              'runsOutAt': '2026-11-15T03:00:00Z',
              'runsOut': 90,
              'unit': 'credits',
            },
            {
              'models': ['dfmodel'],
              'runsOutAt': '2026-11-17T02:00:00Z',
              'runsOut': 24.5,
              'unit': 'credits',
              'balance': 24.5,
            },
          ],
        ),
        grant(
          'first',
          'workbuddy',
          [
            {'id': 'deepseek-v4.1-flash'},
          ],
          windows: [
            {
              'models': ['deepseek-v4.1-flash'],
              'runsOutAt': '2026-11-16T02:00:00Z',
              'runsOut': 12.25,
              'unit': 'credits',
              'limit': 20,
              'amount': 7.75,
            },
          ],
        ),
        grant(
          'unknown',
          'loomy',
          [
            {'id': 'DeepSeek-V4.1-Flash'},
          ],
          windows: [
            {
              'balance': 200,
              'unit': 'credits',
              'resetsAt': '2026-11-15T02:30:00Z',
            },
          ],
        ),
      ],
      const {},
      now,
    );
    final rows = models.single.bindings;
    expect(rows.map((b) => b.account.key), ['first', 'later', 'unknown']);
    expect(rows.first.expiry!.at, DateTime.utc(2026, 11, 16, 2));
    expect(rows.first.expiry!.amount!.amount, 12.25);
    expect(rows.first.expiry!.amount!.unit, 'credits');
    expect(rows.last.expiry, isNull);
  });

  test('exhausted and expired entitlements cannot lead a new session', () {
    final models = pluginModelCatalog(
      [
        grant(
          'empty',
          'qoder',
          [
            {'id': 'dfmodel'},
          ],
          windows: [
            {
              'balance': 0,
              'unit': 'credits',
              'runsOutAt': '2026-11-15T03:00:00Z',
              'runsOut': 0,
            },
          ],
        ),
        grant(
          'expired',
          'qoder',
          [
            {'id': 'dfmodel'},
          ],
          windows: [
            {
              'balance': 9,
              'unit': 'credits',
              'runsOutAt': '2026-11-14T03:00:00Z',
              'runsOut': 9,
            },
          ],
        ),
        grant(
          'live',
          'qoder',
          [
            {'id': 'dfmodel'},
          ],
          windows: [
            {'balance': 5, 'unit': 'credits'},
          ],
        ),
      ],
      const {},
      now,
    );
    expect(models.single.availableAccounts, 1);
    expect(models.single.preferred!.account.key, 'live');
    expect(
      models.single.bindings
          .singleWhere((b) => b.account.key == 'expired')
          .status,
      ModelQuotaStatus.expired,
    );
  });

  test('order and per-model account preferences preserve the many-to-many relationship', () {
    final models = pluginModelCatalog(
      [
        grant('same', 'qoder', [
          {'id': 'dfmodel'},
          {'id': 'dmodel'},
        ]),
      ],
      {
        'order': ['deepseek-v4-pro', 'deepseek-flash'],
        'accounts': {
          'deepseek-flash': {'same': false},
        },
      },
      now,
    );
    expect(models.map((m) => m.id), ['deepseek-v4-pro', 'deepseek-flash']);
    expect(models.first.preferred!.account.key, 'same');
    expect(models.last.availableAccounts, 0);
    expect(
      models.last.bindings.single.account,
      same(models.first.bindings.single.account),
    );
  });
}
