import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/magpie_connection.dart';
import '../lib/magpie_model_routing.dart';
import '../lib/plugin_accounts.dart';
import '../lib/plugin_model_catalog.dart';

PluginModelGrant grant(String key, {String? expiry, bool enabled = true}) =>
    PluginModelGrant(
      PluginAccount(
        key: key,
        active: true,
        facts: {'provider': 'qoder', 'registrationId': key},
        models: [
          {'id': 'dfmodel'},
          {'id': 'dmodel'},
          {
            'id': 'image',
            'name': 'Image',
            'outputs': ['image'],
          },
        ],
        usage: expiry == null
            ? null
            : {
                'windows': [
                  {
                    'balance': 10,
                    'runsOut': 10,
                    'unit': 'credits',
                    'runsOutAt': expiry,
                  },
                ],
              },
      ),
      'synthetic',
      enabled,
    );

void main() {
  late List<List<String>> calls;
  late MagpieConnection client;
  setUp(() {
    calls = [];
    client = MagpieConnection(
      run: (args, {input}) async {
        calls.add(args);
        if (args.join(' ') == 'plugin list --json') {
          return jsonEncode({
            'providers': [
              {
                'id': 'loongpass',
                'accountId': 'late',
                'accounts': [
                  for (final key in ['late', 'early', 'unknown', 'blocked'])
                    {'accountId': key},
                ],
              },
            ],
          });
        }
        return '';
      },
    );
  });

  List<PluginModel> catalog([Map settings = const {}]) => pluginModelCatalog(
    [
      grant('late', expiry: '2026-11-19T00:00:00Z'),
      grant('early', expiry: '2026-11-18T00:00:00Z'),
      grant('unknown'),
      grant('blocked', enabled: false),
    ],
    settings,
    DateTime.utc(2026, 11, 17),
  );

  test('default publication creates only Auto in model then exact account expiry order', () async {
    await client.syncRouting('/bridge', MagpieModelRouting(catalog()));
    final groups = calls.where((c) => c.first == 'group').toList();
    expect(groups, hasLength(1));
    expect(
      groups.single,
      contains(
        'models=loongpass/accounts/early/qoder/dfmodel,loongpass/accounts/late/qoder/dfmodel,loongpass/accounts/unknown/qoder/dfmodel,loongpass/accounts/early/qoder/dmodel,loongpass/accounts/late/qoder/dmodel,loongpass/accounts/unknown/qoder/dmodel,loongpass/accounts/early/qoder/image,loongpass/accounts/late/qoder/image,loongpass/accounts/unknown/qoder/image',
      ),
    );
    expect(groups.single, contains('routing=order'));
    expect(groups.single, contains('stays=session'));
    expect(calls, contains(equals(['provider', 'listed', 'loongpass', 'no'])));
    expect(
      calls,
      contains(
        equals(['provider', 'account-models', 'loongpass', 'blocked', 'auto']),
      ),
    );
    final account = calls.singleWhere(
      (c) => c.length > 3 && c[1] == 'account-models' && c[3] == 'early',
    );
    expect(account.skip(4), [
      'accounts/early/qoder/dfmodel',
      'accounts/early/qoder/dmodel',
      'accounts/early/qoder/image',
    ]);
    final options = jsonDecode(
      calls.singleWhere((c) => c[1] == 'options').last,
    );
    expect(options, {
      'routes': {'loongpass/auto': 'group/loongpass-auto'},
    });
  });

  test(
    'manual publication is independent of Auto and requires an official model',
    () async {
      final models = catalog({
        'version': 2,
        'models': {'deepseek-flash': false},
        'published': {'deepseek-flash': true, 'image': true},
      });
      final flash = models.singleWhere((m) => m.id == 'deepseek-flash');
      await client.syncRouting(
        '/bridge',
        MagpieModelRouting(models, priority: AutoRoutingPriority.creditExpiry),
      );
      final groups = calls.where((c) => c.first == 'group').toList();
      expect(groups.map((c) => c[2]), [flash.groupId, 'loongpass-auto']);
      expect(
        groups.last.lastWhere((c) => c.startsWith('models=')),
        isNot(contains('/dfmodel')),
      );
      expect(
        groups.first.lastWhere((c) => c.startsWith('models=')),
        contains('/dfmodel'),
      );
      expect(groups.first, contains('name=deepseek-flash'));
      expect(
        groups.last.lastWhere((c) => c.startsWith('models=')),
        contains('/image'),
      );
      expect(flash.publicId, startsWith('group/'));
    },
  );

  test(
    'unpublishing removes owned model groups while Auto keeps its candidates',
    () async {
      final models = catalog();
      await client.syncRouting(
        '/bridge',
        MagpieModelRouting(models),
        previousGroups: {'loongpass-auto', ...models.map((m) => m.groupId)},
      );
      final removed = calls
          .where((c) => c.first == 'group' && c[1] == 'rm')
          .map((c) => c[2]);
      expect(removed.toSet(), models.map((m) => m.groupId).toSet());
      expect(removed, isNot(contains('loongpass-auto')));
      expect(
        calls.where((c) => c.first == 'group' && c[1] == 'set'),
        hasLength(1),
      );
    },
  );

  test(
    'empty routing serves none and removes the old outer group before children',
    () async {
      await client.syncRouting(
        '/bridge',
        MagpieModelRouting(
          catalog({'version': 2, 'defaultModelEnabled': false}),
        ),
        previousGroups: {'loongpass-model', 'loongpass-auto'},
      );
      expect(
        calls,
        contains(equals(['provider', 'models', 'loongpass', 'none'])),
      );
      expect(calls.where((c) => c.first == 'group').map((c) => c[2]), [
        'loongpass-auto',
        'loongpass-model',
      ]);
      expect(jsonDecode(calls.singleWhere((c) => c[1] == 'options').last), {
        'routes': {},
      });
    },
  );

  test('routing options target the registered clean bridge path', () async {
    final bridge =
        '${Directory.systemTemp.path}${Platform.pathSeparator}bridge';
    await client.syncRouting(
      '$bridge${Platform.pathSeparator}.',
      MagpieModelRouting([]),
    );
    expect(calls.singleWhere((c) => c[1] == 'options')[2], bridge);
  });

  test('missing groups are created before publishing aliases and failures remain retryable', () async {
    var fail = true;
    final run = client;
    client = MagpieConnection(
      run: (args, {input}) async {
        if (args.first == 'group' && args[1] == 'set') {
          calls.add(args);
          throw const MagpieCommandFailure(missingGroup: true);
        }
        if (args.first == 'group' && args[1] == 'add' && fail) {
          calls.add(args);
          throw const MagpieCommandFailure();
        }
        // Retain the native listing fixture at the external process boundary.
        if (args.join(' ') == 'plugin list --json') {
          return '{"providers":[{"id":"loongpass","accountId":"late"}]}';
        }
        calls.add(args);
        return '';
      },
    );
    await expectLater(
      client.syncRouting('/bridge', MagpieModelRouting(catalog())),
      throwsA(isA<MagpieCommandFailure>()),
    );
    expect(calls.where((c) => c[1] == 'options'), isEmpty);
    fail = false;
    calls.clear();
    await client.syncRouting('/bridge', MagpieModelRouting(catalog()));
    expect(calls.where((c) => c[1] == 'add'), hasLength(1));
    expect(calls.last[1], 'options');
    // Also exercise normal updates after native creation.
    await run.syncRouting('/bridge', MagpieModelRouting(catalog()));
  });
}
