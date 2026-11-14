import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/magpie_connection.dart';
import '../lib/plugin_accounts.dart';
import '../lib/plugin_model_catalog.dart';

void main() {
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
        if (args[1] == 'set')
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
