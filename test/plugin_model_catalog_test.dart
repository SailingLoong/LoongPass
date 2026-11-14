import 'package:flutter_test/flutter_test.dart';

import '../lib/plugin_accounts.dart';
import '../lib/plugin_model_catalog.dart';

final now = DateTime.utc(2026, 11, 15, 2);

PluginModelGrant grant(
  String key,
  String provider,
  List<Map<String, dynamic>> models, {
  List<Map<String, dynamic>> windows = const [],
  bool enabled = true,
}) => PluginModelGrant(
  PluginAccount(
    key: key,
    facts: {'provider': provider, 'label': key, 'registrationId': key},
    active: true,
    models: models,
    usage: {'windows': windows},
  ),
  'synthetic',
  enabled,
);

void main() {
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
