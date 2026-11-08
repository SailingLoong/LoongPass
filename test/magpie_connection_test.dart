import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/magpie_connection.dart';
import '../lib/plugin_accounts.dart';
import '../lib/plugin_model_service.dart';

void main() {
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
          return jsonEncode({
            'providers': [
              {
                'id': 'loongpass',
                'accounts': [
                  {'accountId': 'zcode#saved'},
                ],
              },
            ],
          });
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
            return jsonEncode({
              'providers': [
                {
                  'id': 'loongpass',
                  'accounts': missing
                      ? []
                      : [
                          {'accountId': 'zcode#saved'},
                        ],
                },
              ],
            });
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
