import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/plugin_account_migration.dart';
import '../lib/plugin_migration.dart';
import '../lib/plugin_runtime.dart';
import '../lib/account_document_store.dart';

void main() {
  Map<String, dynamic> source(Map<String, dynamic> accounts) => {
    'accounts': accounts,
  };
  test('native migration preserves regional identity, grant kind, expiry units and claims', () {
    final jwt =
        'e30.${base64Url.encode(utf8.encode('{"exp":1800000000}')).replaceAll('=', '')}.signature';
    final accounts = convertPluginAccounts({
      'MiniMax-cn': source({
        'a': {
          'uid': '17',
          'label': 'same',
          'accessToken': 'mm-cn',
          'refreshToken': 'mm-refresh',
          'expiresAtMs': 1800000000000,
          'automatic': false,
          'operation': {'state': 'unknown', 'points': 12.5},
        },
      }),
      'MiniMax-global': source({
        'b': {
          'uid': '17',
          'label': 'same',
          'accessToken': 'mm-global',
          'expiresAtMs': 1800000000000,
        },
      }),
      'Qoder-cn': source({
        'q-1': {
          'label': 'Q',
          'token': 'qd',
          'refreshToken': 'qr',
          'expiresAt': 1800000000000,
          'machineId': 'fixture-device',
        },
      }),
      'TRAE-cn': source({
        't-1': {
          'uid': 't-1',
          'label': 'T',
          'token': 'tt',
          'refreshToken': 'client-owned',
          'owner': 'officialClient',
          'expiresAt': 1800000000000,
          'device': {
            'DeviceID': 'device-t',
            'MachineID': 'machine-t',
            'DevicePublicKey': 'public',
          },
          'privateKeyPEM': 'private',
        },
      }),
      'WorkBuddy': {
        'w': {
          'state': 'active',
          'uid': 'w-1',
          'domain': 'www.workbuddy.cn',
          'endpoint': 'www.workbuddy.cn',
          'accessToken': 'wa',
          'refreshToken': 'wr',
          'expiresAt': 1800000000000,
        },
      },
      'ZCode': source({
        'z-cn': {
          'uid': '1',
          'label': 'Z',
          'family': 'bigmodel',
          'token': jwt,
          'context': {'deviceMid': 'device-z'},
          'claims': {
            'plan': {
              'state': 'pending',
              'previous': ['receipt-1'],
            },
          },
          'bindingHistory': [
            {
              'claims': {
                'old-plan': {'state': 'pending'},
              },
            },
          ],
        },
        'z-global': {
          'uid': '1',
          'label': 'Z',
          'family': 'zai',
          'token': jwt,
          'context': {'deviceMid': 'device-z2'},
        },
      }),
      'RewardChannels': source({
        'l1': {
          'provider': 'loomy',
          'identity': 'u1',
          'label': '138****1234',
          'credentials': {'access_token': 'ls1', 'userid': 'u1'},
        },
        'l2': {
          'provider': 'loomy',
          'identity': 'u2',
          'label': '138****1234',
          'credentials': {'access_token': 'ls2', 'userid': 'u2'},
        },
      }),
    });
    expect(accounts.length, 9);
    expect(accounts.map((a) => a.key).toSet().length, 9);
    final bySource = {for (final a in accounts) '${a.scope}/${a.oldId}': a};
    final mm = bySource['MiniMax-cn/a']!;
    expect(mm.provider, 'minimax-code');
    expect(mm.auth!['realUserID'], '17');
    expect(mm.auth!['refresh'], 'mm-refresh');
    expect(mm.auth!['expires'], 1800000000000);
    expect(mm.facts['automatic'], false);
    expect(mm.facts['legacy']['operation'], {
      'state': 'unknown',
      'points': 12.5,
    });
    final q = bySource['Qoder-cn/q-1']!.auth!;
    expect(
      [q['deviceChat'], q['deviceToken'], q['deviceRefresh'], q['machineId']],
      [true, 'qd', 'qr', 'fixture-device'],
    );
    final t = bySource['TRAE-cn/t-1']!.auth!;
    expect(
      [t['refresh'], t['deviceId'], t['machineId'], t['devicePrivateKey']],
      ['', 'device-t', 'machine-t', 'private'],
    );
    final wb = bySource['WorkBuddy/w']!.auth!;
    expect(wb['source'], isNot('desktop'));
    expect(
      [wb['access'], wb['refresh'], wb['domain']],
      ['wa', 'wr', 'www.workbuddy.cn'],
    );
    final z = bySource['ZCode/z-cn']!;
    expect(z.auth!['expires'], 1800000000000);
    expect(jsonDecode(z.auth!['refresh']), {
      'site': 'bigmodel',
      'jwt': jwt,
      'device': 'device-z',
      'key': '',
    });
    expect(z.auth!['accountId'], 'bigmodel:1');
    expect(z.facts['legacy']['claims']['plan']['state'], 'pending');
    expect(
      z.facts['legacy']['bindingHistory'][0]['claims']['old-plan']['state'],
      'pending',
    );
    expect(bySource['RewardChannels/l1']!.auth!['uid'], 'u1');
    expect(bySource['RewardChannels/l2']!.auth!['uid'], 'u2');
    for (final a in accounts) {
      expect(jsonEncode(a.facts), isNot(contains('mm-refresh')));
      expect(jsonEncode(a.facts), isNot(contains('client-owned')));
      expect(jsonEncode(a.facts), isNot(contains(jwt)));
    }
  });

  test(
    'unknown rotations stay visible but cannot become active native grants',
    () {
      final values = convertPluginAccounts({
        'MiniMax-cn': source({
          'a': {
            'uid': '17',
            'label': 'A',
            'accessToken': 'a',
            'refreshToken': 'spent',
            'expiresAtMs': 1800000000000,
            'refreshPending': true,
          },
        }),
        'WorkBuddy': {
          'w': {
            'state': 'rotationPending',
            'uid': 'w-1',
            'domain': 'www.workbuddy.cn',
            'accessToken': 'a',
            'refreshToken': 'spent',
          },
        },
      });
      expect(values.length, 2);
      for (final value in values) {
        expect(value.auth, isNull);
        expect(value.facts['quarantine'], 'refresh_unknown');
      }
    },
  );

  test(
    'interrupted migration resumes without restoring an old rotated grant',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'loongpass-migration-',
      );
      final runtime = await PluginRuntime.start(
        executable: Platform.environment['LOONGPASS_BUN'] ?? 'bun',
        hostPath: File('runtime/vendor/magpie/host.js').absolute.path,
        launcherPath: File('runtime/launcher.mjs').absolute.path,
        directory: root.path,
        plugins: [
          {
            'spec': 'fixture',
            'target': File('test/fixtures/native_plugin.mjs').absolute.path,
          },
        ],
      );
      try {
        final backup = MemoryMigrationStore('backup');
        final facts = MemoryMigrationStore('facts')..failNext = true;
        final sources = {
          'MiniMax-cn': source({
            'a': {
              'uid': '17',
              'label': 'A',
              'accessToken': 'original',
              'refreshToken': 'refresh-once',
              'expiresAtMs': 1800000000000,
            },
          }),
        };
        var retired = false;
        final migrator = PluginMigration(
          runtime: runtime,
          directory: root.path,
          backup: backup,
          facts: facts,
          retireSources: (_) async {
            retired = true;
          },
        );
        await expectLater(
          migrator.run(() async => sources),
          throwsA(isA<StateError>()),
        );
        expect(retired, isTrue);
        final key = convertPluginAccounts(sources).single.key;
        final savedFile = File('${root.path}/plugin-auth.json');
        final saved = jsonDecode(await savedFile.readAsString());
        expect(saved[key]['access'], 'original');
        await runtime.call('import', {
          'provider': 'minimax-code',
          'key': key,
          'auth': {
            ...Map<String, dynamic>.from(saved[key]),
            'access': 'renewed',
            'refresh': 'next-refresh',
          },
        });
        await migrator.run(
          () async => throw StateError('Retired stores must not be read again'),
        );
        expect(
          jsonDecode(await savedFile.readAsString())[key]['access'],
          'renewed',
        );
        expect((await facts.read()).data['accounts'][key]['uid'], '17');
        expect((await facts.read()).data['migrationComplete'], true);
        expect(
          (await backup.read())
              .data['sources']['MiniMax-cn']['accounts']['a']['accessToken'],
          'original',
        );
      } finally {
        await runtime.close();
        await root.delete(recursive: true);
      }
    },
  );
}

class MemoryMigrationStore implements AccountDocumentStore {
  MemoryMigrationStore(this.identity);
  @override
  final String identity;
  int revision = 0;
  Map<String, dynamic> data = {};
  bool failNext = false;
  @override
  Future<AccountDocument> read() async =>
      AccountDocument(revision, jsonDecode(jsonEncode(data)));
  @override
  Future<void> write(int expectedRevision, Map<String, dynamic> value) async {
    if (failNext) {
      failNext = false;
      throw StateError('interrupted');
    }
    if (revision != expectedRevision) throw StateError('revision mismatch');
    revision++;
    data = jsonDecode(jsonEncode(value));
  }
}
