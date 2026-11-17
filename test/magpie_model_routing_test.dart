import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/magpie_connection.dart';
import '../lib/plugin_accounts.dart';
import '../lib/plugin_model_catalog.dart';

void main() {
  test('named models share a native route across regions and respect selection', () async {
    final calls = <List<String>>[];
    final client = MagpieConnection(
      run: (args, {input}) async {
        calls.add(args);
        if (args.join(' ') == 'plugin list --json') {
          return '{"providers":[{"id":"loongpass","accountId":"cn","accounts":[{"accountId":"cn"},{"accountId":"global"},{"accountId":"unselected"}]}]}';
        }
        return '';
      },
    );
    final grants = [
      for (final (key, provider, date) in [
        ('cn', 'minimax-code', '2026-11-17T00:00:00Z'),
        ('global', 'minimax-code-global', '2026-12-06T00:00:00Z'),
      ])
        PluginModelGrant(
          PluginAccount(
            key: key,
            active: true,
            facts: {'provider': provider, 'registrationId': key},
            models: [
              {
                'id': 'MiniMax-Image',
                'name': 'MiniMax Image',
                'outputs': ['image'],
              },
            ],
            usage: {
              'windows': [
                {
                  'balance': 10,
                  'runsOut': 10,
                  'unit': 'credits',
                  'runsOutAt': date,
                },
              ],
            },
          ),
          'synthetic',
          true,
        ),
    ];
    final models = pluginModelCatalog(grants, {}, DateTime.utc(2026, 11, 16));
    await client.syncRouting('/bridge', models);
    // Native group creation resolves exposed models, so explicitly publish the
    // selected catalog rather than relying on Magpie's default short picker.
    expect(
      calls,
      contains(
        equals([
          'provider',
          'set',
          'loongpass',
          'models=accounts/cn/minimax-code/MiniMax-Image,accounts/global/minimax-code-global/MiniMax-Image,auto',
        ]),
      ),
    );
    final groups = calls.where((c) => c.first == 'group').toList();
    expect(groups, hasLength(2));
    expect(
      groups.first,
      contains(
        'models=loongpass/accounts/cn/minimax-code/MiniMax-Image,loongpass/accounts/global/minimax-code-global/MiniMax-Image',
      ),
    );
    final options = jsonDecode(
      calls.singleWhere((c) => c[1] == 'options').last,
    );
    final pool = options['pools']['group/${models.single.groupId}'];
    expect(pool['cn']['expires'], [1794873600000]);
    expect(pool['global']['expires'], [1796515200000]);
    expect(groups.first, contains('listed=no'));
    expect(groups.first, contains('name=MiniMax Image'));
    expect(models.single.publicId, 'group/${models.single.groupId}');
    expect(options['routes'].containsKey('loongpass/minimax-image'), isFalse);
    expect(
      calls,
      contains(
        equals([
          'provider',
          'account-models',
          'loongpass',
          'cn',
          'auto',
          'accounts/cn/minimax-code/MiniMax-Image',
        ]),
      ),
    );
    expect(
      calls,
      contains(
        equals([
          'provider',
          'account-models',
          'loongpass',
          'unselected',
          'auto',
        ]),
      ),
    );
    calls.clear();
    await client.syncRouting(
      '/bridge',
      pluginModelCatalog(grants, {
        'version': 2,
        'defaultModelEnabled': false,
      }, DateTime.utc(2026, 11, 16)),
      previousGroups: {models.single.groupId, 'loongpass-auto'},
    );
    expect(
      calls,
      contains(equals(['provider', 'models', 'loongpass', 'none'])),
    );
    final disabled = jsonDecode(
      calls.singleWhere((c) => c[1] == 'options').last,
    );
    expect(disabled['routes'], isEmpty);
    expect(disabled['pools'], isEmpty);
    calls.clear();
    await client.syncRouting('/bridge', models);
    expect(
      calls,
      contains(
        equals([
          'provider',
          'set',
          'loongpass',
          'models=accounts/cn/minimax-code/MiniMax-Image,accounts/global/minimax-code-global/MiniMax-Image,auto',
        ]),
      ),
    );
  });

  test('routing options target the registered clean bridge path', () async {
    final bridge =
        '${Directory.systemTemp.path}${Platform.pathSeparator}bridge';
    final calls = <List<String>>[];
    final client = MagpieConnection(
      run: (args, {input}) async {
        calls.add(args);
        return '[]';
      },
    );
    await client.syncRouting('$bridge${Platform.pathSeparator}.', []);
    expect(calls.singleWhere((args) => args[1] == 'options')[2], bridge);
  });
  test('removing all routes deletes the referencing auto group before its children', () async {
    final present = {'loongpass-model', 'loongpass-auto'};
    final removed = <String>[];
    final client = MagpieConnection(
      run: (args, {input}) async {
        if (args.join(' ') == 'plugin list --json') return '[]';
        if (args.first == 'group' && args[1] == 'rm') {
          if (args[2] != 'loongpass-auto' &&
              present.contains('loongpass-auto')) {
            throw StateError('The child is still referenced by auto');
          }
          present.remove(args[2]);
          removed.add(args[2]);
        }
        return '';
      },
    );
    await client.syncRouting('/bridge', [], previousGroups: Set.of(present));
    expect(present, isEmpty);
    expect(removed, ['loongpass-auto', 'loongpass-model']);
  });
  test('empty routing removes only owned groups and tolerates an already removed group', () async {
    final calls = <List<String>>[];
    final client = MagpieConnection(
      run: (args, {input}) async {
        calls.add(args);
        if (args.join(' ') == 'plugin list --json') return '[]';
        if (args.first == 'group')
          throw const MagpieCommandFailure(missingGroup: true);
        return '';
      },
    );
    await client.syncRouting('/bridge', [], previousGroups: {'loongpass-old'});
    final options = jsonDecode(
      calls.singleWhere((c) => c[1] == 'options').last,
    );
    expect(options['routes'], isEmpty);
    expect(options['pools'], isEmpty);
    expect(calls.last, ['group', 'rm', 'loongpass-old']);
  });
  test('missing groups are created before publishing aliases and ordinary failures remain retryable', () async {
    final calls = <List<String>>[];
    var fail = true;
    final models = pluginModelCatalog(
      [
        PluginModelGrant(
          PluginAccount(
            key: 'a',
            facts: {'provider': 'qoder', 'registrationId': 'r'},
            active: true,
            models: [
              {'id': 'dfmodel'},
            ],
          ),
          'synthetic',
          true,
        ),
      ],
      {},
      DateTime.now(),
    );
    final client = MagpieConnection(
      run: (args, {input}) async {
        calls.add(args);
        if (args.join(' ') == 'plugin list --json')
          return '{"providers":[{"id":"loongpass","accountId":"a"}]}';
        if (args.first == 'group' && args[1] == 'set')
          throw const MagpieCommandFailure(missingGroup: true);
        if (args[1] == 'add' && fail) throw const MagpieCommandFailure();
        return '';
      },
    );
    await expectLater(
      client.syncRouting('/bridge', models),
      throwsA(isA<MagpieCommandFailure>()),
    );
    expect(calls.where((c) => c[1] == 'options'), isEmpty);
    fail = false;
    calls.clear();
    await client.syncRouting('/bridge', models);
    expect(calls.where((c) => c[1] == 'add'), hasLength(2));
    expect(calls.last[1], 'options');
  });
  test('native groups preserve model order, model-scoped expiry, and session affinity', () async {
    final calls = <List<String>>[];
    final client = MagpieConnection(
      run: (args, {input}) async {
        calls.add(args);
        if (args.join(' ') == 'plugin list --json')
          return '{"providers":[{"id":"loongpass","accountId":"a"}]}';
        return '';
      },
    );
    final models = pluginModelCatalog(
      [
        PluginModelGrant(
          PluginAccount(
            key: 'a',
            facts: {'provider': 'qoder', 'registrationId': 'r'},
            active: true,
            models: [
              {'id': 'dfmodel'},
              {'id': 'dmodel'},
            ],
            usage: {
              'windows': [
                {
                  'models': ['dfmodel'],
                  'runsOutAt': '2026-11-16T00:00:00Z',
                  'runsOut': 10,
                  'unit': 'credits',
                },
              ],
            },
          ),
          'synthetic',
          true,
        ),
      ],
      {
        'order': ['deepseek-v4-pro', 'deepseek-flash'],
      },
      DateTime.utc(2026, 11, 15),
    );
    await client.syncRouting(
      '/local/bridge',
      models,
      previousGroups: {'loongpass-old'},
    );
    final groups = calls
        .where((c) => c.first == 'group' && c[1] == 'set')
        .toList();
    expect(groups, hasLength(3));
    expect(groups[0], contains('models=loongpass/qoder/dmodel'));
    expect(groups[1], contains('models=loongpass/qoder/dfmodel'));
    expect(groups.every((c) => c.contains('stays=session')), isTrue);
    expect(groups[0], contains('routing=bridge/quota'));
    expect(
      groups[2],
      contains('models=group/${models[0].groupId},group/${models[1].groupId}'),
    );
    expect(groups[2], contains('routing=order'));
    final options = jsonDecode(
      calls.singleWhere((c) => c.first == 'plugin' && c[1] == 'options').last,
    );
    expect(options['defaultAccount'], 'a');
    expect(
      options['routes']['loongpass/deepseek-flash'],
      'group/${models[1].groupId}',
    );
    expect(options['pools']['group/${models[1].groupId}']['a']['expires'], [
      1794787200000,
    ]);
    expect(
      options['pools']['group/${models[0].groupId}']['a']['expires'],
      isEmpty,
    );
    expect(calls.where((c) => c.first == 'group' && c[1] == 'rm').single, [
      'group',
      'rm',
      'loongpass-old',
    ]);
  });
}
