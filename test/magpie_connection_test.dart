import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/magpie_connection.dart';
import '../lib/plugin_accounts.dart';
import '../lib/plugin_model_service.dart';
import 'magpie_fixture.dart';

void main() {
  test(
    'inspection distinguishes gateway reachability and saved grants',
    () async {
      final calls = <List<String>>[];
      final connection = MagpieConnection(
        run: (args, {input}) async {
          calls.add(args);
          expect(input, isNull);
          if (args.first == 'healthcheck') throw StateError('offline');
          final listing = magpiePluginList(['one']);
          (listing['providers'] as List).add({
            'id': 'other',
            'accounts': [
              {'accountId': 'unrelated'},
            ],
          });
          return jsonEncode(listing);
        },
      );
      final result = await connection.inspect();
      expect(result.executableFound, isTrue);
      expect(result.gatewayReady, isFalse);
      expect(result.accountIds, {'one'});
      expect(calls, [
        ['healthcheck'],
        ['plugin', 'list', '--json'],
      ]);
    },
  );

  test(
    'empty native list is disconnected; unknown output stays unknown',
    () async {
      final unsigned = magpiePluginList([]);
      unsigned['providers'][0]['accounts'] = null;
      for (final output in [
        '[]',
        '{"providers":[]}',
        jsonEncode(unsigned),
        '{"providers":null}',
        '{"providers":[{"id":"loongpass","accounts":[{}]}]}',
        'not json',
      ]) {
        final connection = MagpieConnection(
          run: (args, {input}) async =>
              args.first == 'healthcheck' ? '' : output,
        );
        final result = await connection.inspect();
        expect(result.gatewayReady, isTrue);
        expect(
          result.accountIds,
          ['[]', '{"providers":[]}', jsonEncode(unsigned)].contains(output)
              ? isEmpty
              : isNull,
        );
      }
    },
  );

  test('disabled, failed, missing or superseded plugin cannot certify cached accounts', () async {
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (v) => v['plugins'][0]['off'] = true,
      (v) => v['loaded'][0]['error'] = 'private upstream details',
      (v) => v['loaded'] = [],
      (v) => v['loaded'][0]['provides'] = ['other'],
      (v) => v['loaded'][0]['servedBy'] = {'loongpass': '/other'},
    ]) {
      final listing = magpiePluginList(['cached-account']);
      mutate(listing);
      final connection = MagpieConnection(
        run: (args, {input}) async =>
            args.first == 'healthcheck' ? '' : jsonEncode(listing),
      );
      final result = await connection.inspect();
      expect(result.gatewayReady, true);
      expect(result.accountIds, isNull);
    }
  });

  test(
    'missing executable needs installation, not an account reconnect',
    () async {
      final result = await MagpieConnection(
        locateExecutable: () async => throw StateError('not found'),
      ).inspect();
      expect(result.executableFound, isFalse);
      expect(result.gatewayReady, isNull);
      expect(result.accountIds, isNull);
    },
  );

  final grant = PluginModelGrant(
    PluginAccount(
      key: 'zcode#saved',
      facts: {'provider': 'zcode', 'registrationId': 'registration'},
      active: true,
      models: [],
    ),
    'local-grant',
    true,
  );
  test(
    'native connection retires only owned legacy sources after verification',
    () async {
      final calls = <List<String>>[], inputs = <String>[];
      var backedUp = false;
      final connection = MagpieConnection(
        run: (args, {input}) async {
          calls.add(args);
          if (input != null) inputs.add(input);
          if (args.contains('rm')) expect(backedUp, isTrue);
          return jsonEncode(magpiePluginList(['zcode#saved']));
        },
        readProviders: () async => [
          {
            'id': 'loongpass',
            'anthropic': 'http://127.0.0.1:3426',
            'key': 'old-pool',
          },
          {
            'id': 'loongpass-foreign',
            'anthropic': 'http://127.0.0.1:3426',
            'key': 'foreign',
          },
          {
            'id': 'loongpass-remote',
            'anthropic': 'https://example.com',
            'key': 'old-pool',
          },
          {
            'id': 'other',
            'anthropic': 'http://127.0.0.1:3426',
            'key': 'old-pool',
          },
        ],
      );
      await connection.connect(
        '/private/bridge',
        Uri.parse('http://127.0.0.1:3426'),
        [grant],
        legacyKeys: {'old-pool'},
        saveBackup: (rows) async {
          expect(rows.map((r) => r['id']), ['loongpass']);
          backedUp = true;
        },
      );
      expect(calls.where((a) => a.contains('rm')).toList(), [
        ['provider', 'rm', 'loongpass'],
      ]);
      expect(calls.expand((a) => a), isNot(contains('local-grant')));
      expect(
        inputs.single,
        'http://127.0.0.1:3426\nzcode#saved\nlocal-grant\n',
      );
      expect(
        calls.indexWhere((a) => a.contains('--json')),
        lessThan(calls.indexWhere((a) => a.contains('rm'))),
      );
    },
  );
  test(
    'missing native account or backup failure leaves legacy source intact',
    () async {
      for (final missing in [true, false]) {
        final calls = <List<String>>[];
        final connection = MagpieConnection(
          run: (args, {input}) async {
            calls.add(args);
            return jsonEncode(magpiePluginList(missing ? [] : ['zcode#saved']));
          },
          readProviders: () async => [
            {
              'id': 'loongpass',
              'anthropic': 'http://127.0.0.1:3426',
              'key': 'old',
            },
          ],
        );
        await expectLater(
          connection.connect(
            '/bridge',
            Uri.parse('http://127.0.0.1:3426'),
            [grant],
            legacyKeys: {'old'},
            saveBackup: (_) async => throw StateError('Backup unavailable'),
          ),
          throwsStateError,
        );
        expect(calls.any((a) => a.contains('rm')), isFalse);
      }
    },
  );
}
