import 'package:flutter_test/flutter_test.dart';

import '../lib/plugin_accounts.dart';
import '../lib/plugin_credit_balance.dart';
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
  test('expiring batch shows only matching published, available, paid models of its account', () {
    final later = now.add(const Duration(days: 2)),
        earlier = now.add(const Duration(days: 1));
    Map<String, dynamic> window(DateTime time, List<String> models) => {
      'models': models,
      'balance': 50,
      'runsOut': 12.5,
      'unit': 'credits',
      'runsOutAt': time.toIso8601String(),
    };
    final account = grant(
      'one',
      'workbuddy',
      [
        {'id': 'glm-5.3'},
        {'id': 'MiniMax-M3'},
        {'id': 'deepseek-flash', 'free': true},
      ],
      windows: [
        window(earlier, ['MiniMax-M3']),
        window(later, ['glm-5.3', 'deepseek-flash']),
      ],
    );
    final other = grant(
      'two',
      'workbuddy',
      [
        {'id': 'MiniMax-M3'},
      ],
      windows: [
        window(later, ['MiniMax-M3']),
      ],
    );
    final settings = {
      'version': 4,
      'published': {
        'glm-5.3': true,
        'MiniMax-M3': true,
        'deepseek-flash': true,
      },
    };
    final catalog = pluginModelCatalog([account, other], settings, now);
    final batches = pluginCreditExpiryBatches(account.account.usage, {}, now);
    expect(
      spendableModels(catalog, account.account, batches.last, batches, now),
      ['glm-5.3'],
    );
    expect(
      spendableModels(catalog, account.account, batches.first, batches, now),
      ['MiniMax-M3'],
    );
    expect(
      spendableModels(catalog, account.account, batches.first, [
        ...batches,
        batches.first,
      ], now),
      isEmpty,
    );
    expect(
      spendableModels(
        pluginModelCatalog([account], {}, now),
        account.account,
        batches.last,
        batches,
        now,
      ),
      isEmpty,
    );
  });

  test('versioned preferences retain missing catalogs and prioritize explicit choices', () {
    final legacy = {
      'models': {'glm-5.3': false},
      'accounts': {
        'trae-cn/glm-5.3-max': {'cn': false},
      },
      'order': ['trae-cn/glm-5.3-max', 'glm-5.3'],
    };
    final saved = upgradeModelRouting(legacy);
    expect(pluginModelCatalog([], saved, now), isEmpty);
    final grants = [
      grant('cn', 'trae-cn', [
        {'id': 'glm-5.3'},
        {'id': 'glm-5.3-max'},
      ]),
    ];
    final restored = pluginModelCatalog(grants, saved, now).single;
    expect(restored.published, isFalse);
    expect(restored.availableAccounts, 0);
    expect(saved['legacy'], legacy);
    saved['published'] = {'glm-5.3': true};
    final enabled = pluginModelCatalog(grants, saved, now).single;
    expect(enabled.availableAccounts, 0);
    saved['accounts'] = {
      'glm-5.3': {'cn': true},
    };
    expect(
      pluginModelCatalog(
        grants,
        saved,
        now,
      ).single.bindings.every((b) => b.enabled),
      isTrue,
    );
    saved['published'] = {'glm-5.3': false};
    expect(pluginModelCatalog(grants, saved, now).single.published, isFalse);
  });

  test(
    'legacy alias participation survives grouping and explicit new choices',
    () {
      final grants = [
        grant('cn', 'trae-cn', [
          {'id': 'glm-5.3'},
          {'id': 'glm-5.3-max'},
        ]),
      ];
      for (final (disabled, enabled) in [
        ('trae-cn/glm-5.3-max', 'glm-5.3'),
        ('glm-5.3', 'trae-cn/glm-5.3-max'),
      ]) {
        final settings = {
          'models': {disabled: false, enabled: true},
        };
        final model = pluginModelCatalog(grants, settings, now).single;
        expect(model.published, isFalse);
        expect(model.availableAccounts, 1);
        expect(model.bindings.where((b) => b.enabled).map((b) => b.nativeId), [
          disabled == 'glm-5.3' ? 'glm-5.3-max' : 'glm-5.3',
        ]);
        final retained = upgradeModelRouting(settings)
          ..['published'] = {'glm-5.3': true};
        expect(
          pluginModelCatalog(
            grants,
            retained,
            now,
          ).single.bindings.where((b) => b.enabled).map((b) => b.nativeId),
          model.bindings.where((b) => b.enabled).map((b) => b.nativeId),
        );
      }
      final allDisabled = upgradeModelRouting({
        'models': {'glm-5.3': false, 'trae-cn/glm-5.3-max': false},
      });
      expect(
        pluginModelCatalog(grants, allDisabled, now).single.published,
        isFalse,
      );
      allDisabled['published'] = {'glm-5.3': true};
      expect(
        pluginModelCatalog(grants, allDisabled, now).single.availableAccounts,
        0,
      );
      allDisabled['accounts'] = {
        'glm-5.3': {'cn': true},
      };
      expect(
        pluginModelCatalog(grants, allDisabled, now).single.availableAccounts,
        1,
      );
    },
  );

  test('published TRAE aliases merge without changing account request IDs', () {
    final grants = [
      grant('qoder', 'qoder-cn', [
        {'id': 'glm-5.3'},
        {'id': 'dfmodel'},
      ]),
      grant(
        'trae',
        'trae-cn',
        [
          {'id': 'DeepSeek-V4-Flash-Official', 'name': 'DeepSeek-V4-Flash'},
          {
            'id': 'DeepSeek-V4-Flash-Official-max',
            'name': 'DeepSeek-V4-Flash (Max)',
            'apiId': 'trae-max-wire',
          },
        ],
        windows: [
          {
            'models': ['DeepSeek-V4-Flash-Official-max'],
            'balance': 37.25,
            'unit': 'credits',
            'runsOut': 12.5,
            'runsOutAt': '2026-11-16T03:00:00Z',
          },
        ],
      ),
    ];
    final settings = {
      'version': 2,
      'defaultModelEnabled': false,
      'order': ['deepseek-v4-flash-(max)', 'glm-5.3'],
      'models': {'deepseek-v4-flash-(max)': true},
      'published': {'deepseek-v4-flash-(max)': true},
      'accounts': {
        'deepseek-v4-flash': {'trae': false},
      },
    };

    final catalog = pluginModelCatalog(grants, settings, now);
    expect(catalog.map((model) => model.id), ['deepseek-flash', 'glm-5.3']);
    final flash = catalog.first;
    expect(flash.name, 'deepseek-flash');
    expect(flash.published, isTrue);
    expect(flash.bindings.map((b) => b.nativeId), [
      'DeepSeek-V4-Flash-Official-max',
      'dfmodel',
      'DeepSeek-V4-Flash-Official',
    ]);
    expect(flash.bindings.first.native['apiId'], 'trae-max-wire');
    expect(flash.bindings.first.expiry!.amount!.amount, 12.5);
    expect(flash.bindings.first.expiry!.amount!.unit, 'credits');
    expect(flash.bindings.last.enabled, isFalse);

    final edited = upgradeModelRouting(settings)
      ..['published'] = {'deepseek-flash': false};
    expect(pluginModelCatalog(grants, edited, now).first.published, isFalse);
    grants.last.account.models.clear();
    expect(pluginModelCatalog(grants, settings, now).first.published, isTrue);
  });

  test('Qoder resolves a reused slot using each account model label', () {
    for (final (name, expected) in [
      ('Qwen3.7-Max', 'qwen3.7-max'),
      ('Qwen4-Max', 'qwen4-max'),
      ('Qwen4-Max-Preview', 'qwen4-max-preview'),
      ('unknown', null),
    ]) {
      expect(
        officialModelId('qoder-cn', {'id': 'qmodel_latest', 'name': name}),
        expected,
      );
    }
    expect(
      officialModelId('qoder-cn', {
        'id': 'qmodel_latest_preview',
        'name': 'Qwen4-Max-Preview',
      }),
      'qwen4-max-preview',
    );
  });

  test('regional channel IDs resolve official model aliases', () {
    for (final (provider, native, expected) in [
      ('trae-cn', 'glm-5.3-max', 'glm-5.3'),
      ('trae-global', 'gemini-3.1-pro-max', 'gemini-3.1-pro-preview'),
      ('trae-cn', 'glm-5.1', 'glm-5.1'),
      ('trae-cn', 'glm-5', 'glm-5'),
      ('trae-cn', 'glm-4.7', 'glm-4.7'),
      ('trae-cn', 'glm-4.6', 'glm-4.6'),
      ('qoder-cn', 'dfmodel', 'deepseek-flash'),
      ('trae-cn', 'DeepSeek-V4-Flash-Official-max', 'deepseek-flash'),
      ('trae-cn', 'DeepSeek-V4-Pro-Official-max', 'deepseek-v4-pro'),
      ('trae-cn', 'qwen4-max-max', 'qwen4-max'),
      ('trae-cn', 'qwen3.8-max', 'qwen3.8-max'),
      ('trae-cn', 'kimi-k2.8-preview-max', 'kimi-for-coding'),
      ('trae-cn', 'kimi-k3.1-pro-auto-max', 'kimi-k3.1-pro'),
      ('trae-cn', 'mimo-v2.6-flash-max', 'mimo-v2.6-flash'),
      ('trae-cn', 'step-5-preview-max', 'step-5-preview'),
      ('workbuddy', 'hy4std', 'hy4'),
      ('workbuddy', 'hy4flash-free', 'hy4-flash'),
      ('workbuddy', 'hy4flash', 'hy4-flash'),
      ('zcode', 'GLM-5.3-Flash-Trial', 'glm-5.3-flash'),
      ('qoder-cn', 'dfmodel@1m', 'deepseek-flash'),
    ]) {
      expect(officialModelId(provider, {'id': native}), expected);
    }
  });

  test(
    'channel labels identify Seed retargeting and the Loomy Spark alias',
    () {
      for (final (provider, id, name, expected) in [
        (
          'trae-cn',
          'Doubao-Seed-2.0-Code',
          'Doubao-Seed-2.1-Turbo',
          'doubao-seed-2.1-turbo',
        ),
        (
          'trae-cn',
          'Doubao-Seed-2.1-Pro-max',
          'Seed-2.1-Pro-0915 (Max)',
          'doubao-seed-2.1-pro',
        ),
        ('loomy', 'spark-x', 'Spark-X2.5 (限时免费) (x0.0)', 'spark-x2.5'),
      ]) {
        expect(officialModelId(provider, {'id': id, 'name': name}), expected);
      }
    },
  );

  test('a retained group does not enable a disabled alias when another catalog disappears', () {
    final grants = [
      grant('base', 'trae-cn', [
        {'id': 'glm-5.3'},
      ]),
      grant('max', 'trae-cn', [
        {'id': 'glm-5.3-max'},
      ]),
    ];
    final settings = upgradeModelRouting({
      'models': {'trae-cn/glm-5.3-max': false},
    })..['published'] = {'glm-5.3': true};
    expect(
      pluginModelCatalog(grants, settings, now).single.availableAccounts,
      1,
    );
    grants.first.account.models.clear();
    final remaining = pluginModelCatalog(grants, settings, now).single;
    expect(remaining.published, isTrue);
    expect(remaining.availableAccounts, 0);
  });

  test('same named regional models share an expiry-ordered account pool', () {
    final grants = [
      grant(
        'global',
        'minimax-code-global',
        [
          {
            'id': 'MiniMax-Image',
            'name': 'MiniMax Image',
            'outputs': ['image'],
          },
        ],
        windows: [
          {
            'balance': 393.36,
            'runsOut': 393.36,
            'unit': 'credits',
            'runsOutAt': '2026-12-06T00:00:00Z',
          },
        ],
      ),
      grant(
        'cn',
        'minimax-code',
        [
          {
            'id': 'MiniMax-Image',
            'name': 'MiniMax Image',
            'outputs': ['image'],
          },
        ],
        windows: [
          {
            'balance': 278.68,
            'runsOut': 278.68,
            'unit': 'credits',
            'runsOutAt': '2026-11-17T00:00:00Z',
          },
        ],
      ),
    ];
    final model = pluginModelCatalog(grants, {}, now).single;
    expect(model.id, 'minimax-image');
    expect(model.name, 'MiniMax Image');
    expect(model.official, isFalse);
    expect(model.availableAccounts, 2);
    expect(model.bindings.map((b) => b.account.key), ['cn', 'global']);
    expect(model.bindings.first.expiry!.amount!.amount, 278.68);
    expect(model.bindings.first.expiry!.amount!.unit, 'credits');
    expect(model.bindings.last.expiry!.amount!.amount, 393.36);
    expect(model.bindings.map((b) => b.exportedId), [
      'accounts/cn/minimax-code/MiniMax-Image',
      'accounts/global/minimax-code-global/MiniMax-Image',
    ]);

    final migrated = pluginModelCatalog(grants, {
      'order': [
        'minimax-code-global/MiniMax-Image',
        'minimax-code/MiniMax-Image',
      ],
      'models': {'minimax-code/MiniMax-Image': false},
    }, now).single;
    expect(migrated.published, isFalse);
    expect(migrated.preferred, isNull);
    expect(migrated.bindings.first.account.key, 'global');
    expect(
      migrated.bindings.singleWhere((b) => b.account.key == 'cn').enabled,
      isFalse,
    );
  });

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
      {
        'version': 4,
        'published': {'deepseek-flash': true},
      },
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
      const {
        'version': 4,
        'published': {'deepseek-flash': true},
      },
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
        'version': 4,
        'published': {'deepseek-v4-pro': true},
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
