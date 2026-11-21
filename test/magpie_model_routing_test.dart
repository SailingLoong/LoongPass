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
  final flash = 'group/${PluginModel.groupIdFor('deepseek-flash')}';
  final pro = 'group/${PluginModel.groupIdFor('deepseek-v4-pro')}';
  final listing =
      '  Routing groups\n  $pro  Pro\n  group/unrelated  Other\n  $flash  Flash\n';
  setUp(() {
    calls = [];
    client = MagpieConnection(
      run: (args, {input}) async {
        calls.add(args);
        if (args.first == 'models') return listing;
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

  List<PluginModel> catalog([
    Map settings = const {
      'version': 4,
      'published': {'deepseek-flash': true, 'deepseek-v4-pro': true},
    },
  ]) => pluginModelCatalog(
    [
      grant('late', expiry: '2026-11-19T00:00:00Z'),
      grant('early', expiry: '2026-11-18T00:00:00Z'),
      grant('unknown'),
      grant('blocked', enabled: false),
    ],
    settings,
    DateTime.utc(2026, 11, 17),
  );

  test(
    'native Auto names each visible group once in actual Magpie order',
    () async {
      final routing = MagpieModelRouting(catalog());
      await client.syncRouting('/bridge', routing);
      final groups = calls.where((c) => c.first == 'group').toList();
      expect(groups, hasLength(3));
      expect(groups.last, contains('models=$pro,$flash'));
      expect(groups.last, contains('listed=yes'));
      expect(groups.last, contains('routing=order'));
      expect(groups.last, contains('stays=session'));
      expect(routing.preferred!.model.id, 'deepseek-v4-pro');
      expect(routing.availableAccounts, {'early', 'late', 'unknown'});
      expect(
        groups.first,
        contains(
          'models=loongpass/accounts/early/qoder/dfmodel,loongpass/accounts/late/qoder/dfmodel,loongpass/accounts/unknown/qoder/dfmodel',
        ),
      );
      expect(
        calls,
        contains(
          equals([
            'provider',
            'account-models',
            'loongpass',
            'blocked',
            'auto',
          ]),
        ),
      );
      expect(routing.exposed.any((id) => id.endsWith('/image')), isFalse);
    },
  );

  test('expiry mode can only use published bindings despite conflicting legacy Auto flags', () async {
    final routing = MagpieModelRouting(
      catalog({
        'version': 2,
        'models': {'deepseek-flash': false, 'deepseek-v4-pro': true},
        'published': {'deepseek-flash': true, 'image': true},
      }),
      priority: AutoRoutingPriority.creditExpiry,
    );
    await client.syncRouting(
      '/bridge',
      routing,
      previousGroups: {pro.substring(6)},
    );
    final auto = calls.singleWhere(
      (c) => c.length > 2 && c[2] == 'loongpass-auto',
    );
    expect(
      auto,
      contains(
        'models=loongpass/accounts/early/qoder/dfmodel,loongpass/accounts/late/qoder/dfmodel,loongpass/accounts/unknown/qoder/dfmodel',
      ),
    );
    expect(calls, contains(equals(['group', 'rm', pro.substring(6)])));
    expect(routing.aliases['loongpass/deepseek-v4-pro'], isNull);
  });

  test(
    'empty routing serves none and removes the old outer group before children',
    () async {
      await client.syncRouting(
        '/bridge',
        MagpieModelRouting(
          catalog({
            'version': 3,
            'models': {'deepseek-flash': true},
          }),
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
      expect(
        jsonDecode(
          calls.singleWhere((c) => c.length > 1 && c[1] == 'options').last,
        ),
        {'routes': {}},
      );
    },
  );

  test('routing options target the registered clean bridge path', () async {
    final bridge =
        '${Directory.systemTemp.path}${Platform.pathSeparator}bridge';
    await client.syncRouting(
      '$bridge${Platform.pathSeparator}.',
      MagpieModelRouting([]),
    );
    expect(
      calls.singleWhere((c) => c.length > 1 && c[1] == 'options')[2],
      bridge,
    );
  });

  test('missing groups are created before publishing aliases and failures remain retryable', () async {
    var fail = true;
    final run = client;
    client = MagpieConnection(
      run: (args, {input}) async {
        if (args.first == 'models') return listing;
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
    expect(calls.where((c) => c.length > 1 && c[1] == 'options'), isEmpty);
    fail = false;
    calls.clear();
    await client.syncRouting('/bridge', MagpieModelRouting(catalog()));
    expect(calls.where((c) => c.length > 1 && c[1] == 'add'), hasLength(3));
    expect(calls.last[1], 'options');
    // Also exercise normal updates after native creation.
    await run.syncRouting('/bridge', MagpieModelRouting(catalog()));
  });
}
