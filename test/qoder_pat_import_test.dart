import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/qoder_claim.dart';
import '../lib/qoder_pat_import.dart';

// A synthetic swap at the actual open boundary reproduces the reviewed race.
class SwapAtOpen implements File {
  final File selected, other;
  SwapAtOpen(this.selected, this.other);
  @override
  String get path => selected.path;
  @override
  Future<FileStat> stat() => selected.stat();
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    await selected.delete();
    await Link(selected.path).create(other.path);
    return selected.open(mode: mode);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected operation');
}

void main() {
  late Directory temp;
  late File source;
  Map<String, Object?> provider({Object? settings, Object? meta}) => {
    'id': 'synthetic-qoder',
    'name': 'Synthetic Qoder',
    'settingsConfig':
        settings ??
        {
          'env': {'OPENAI_API_KEY': 'SYNTHETIC_PAT'},
        },
    'meta': meta ?? {'providerType': 'qoder_sdk'},
  };
  Future<QoderPatCandidate> read(
    Object json, {
    String id = 'synthetic-qoder',
  }) async {
    await source.writeAsString(jsonEncode(json));
    return QoderPatImport.read(source, providerId: id);
  }

  Matcher fails(String code) =>
      throwsA(isA<QoderFailure>().having((e) => e.code, 'code', code));
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('loongpass-pat-import-');
    source = File('${temp.path}/selected.json');
  });
  tearDown(() async => temp.delete(recursive: true));

  test(
    'explicit selected Provider JSON reads only an in-memory PAT candidate',
    () async {
      final input = provider();
      final candidate = await read(input);
      expect(candidate.providerId, 'synthetic-qoder');
      expect(candidate.useForVerification((value) => value), 'SYNTHETIC_PAT');
      expect(candidate.toString(), 'QoderPatCandidate(redacted)');
      expect(jsonDecode(await source.readAsString()), input);
      expect((await temp.list().toList()).length, 1);
    },
  );
  test(
    'existing plaintext-export format selects exactly one codex Qoder row',
    () async {
      final candidate = await read({
        'exportedAt': '2026-11-03T00:00:00Z',
        'database': {
          'providers': [
            {
              'id': 'other',
              'app_type': 'codex',
              'settings_config': 'UNRELATED_NOT_PARSED',
              'meta': '{}',
            },
            {
              'id': 'synthetic-qoder',
              'app_type': 'codex',
              'settings_config': jsonEncode({
                'env': {'OPENAI_API_KEY': 'SYNTHETIC_PAT'},
              }),
              'meta': jsonEncode({'providerType': 'qoder_sdk'}),
            },
          ],
        },
        'files': {'unrelated': 'SYNTHETIC_UNRELATED_SECRET'},
      });
      expect(candidate.useForVerification((value) => value), 'SYNTHETIC_PAT');
      expect(candidate.toString(), isNot(contains('SYNTHETIC_UNRELATED')));
    },
  );
  test(
    'supported direct fields must agree rather than silently picking one',
    () async {
      for (final settings in [
        {
          'auth': {'OPENAI_API_KEY': 'SYNTHETIC_PAT'},
        },
        {'apiKey': 'SYNTHETIC_PAT'},
        {'api_key': 'SYNTHETIC_PAT'},
        {
          'env': {'OPENAI_API_KEY': ' SYNTHETIC_PAT '},
          'auth': {'OPENAI_API_KEY': 'SYNTHETIC_PAT'},
        },
      ]) {
        expect(
          (await read(
            provider(settings: settings),
          )).useForVerification((v) => v),
          'SYNTHETIC_PAT',
        );
      }
      await expectLater(
        read(provider(settings: {'apiKey': 'FIRST', 'api_key': 'SECOND'})),
        fails('AmbiguousCredential'),
      );
    },
  );
  test(
    'imported generations, pending intents and automatic permissions are not inherited',
    () async {
      final candidate = await read(
        provider(
          meta: {
            'providerType': 'qoder_sdk',
            'qoderCampaignState': {
              'generation': 'FOREIGN',
              'pending': {'id': 'pending'},
              'automatic': {'enabled': true},
            },
          },
        ),
      );
      expect(candidate.providerId, 'synthetic-qoder');
      expect(candidate.toString(), isNot(contains('FOREIGN')));
      expect((await temp.list().toList()).length, 1);
    },
  );
  test(
    'wrong provider or platform and external auth owners are rejected',
    () async {
      await expectLater(
        read(provider(), id: 'not-selected'),
        fails('ProviderNotFound'),
      );
      await expectLater(
        read(provider(meta: {'providerType': 'other'})),
        fails('UnsupportedCredentialSource'),
      );
      for (final owner in [
        'vendor_api_key',
        'managed_account',
        'future_owner',
      ]) {
        await expectLater(
          read(
            provider(
              meta: {
                'providerType': 'qoder_sdk',
                'authBinding': {'source': owner},
              },
            ),
          ),
          fails('UnsupportedCredentialSource'),
        );
      }
      expect(
        (await read(
          provider(
            meta: {
              'providerType': 'qoder_sdk',
              'authBinding': {'source': 'provider_config'},
            },
          ),
        )).providerId,
        'synthetic-qoder',
      );
    },
  );
  test('duplicate selected rows and wrong app type fail closed', () async {
    final row = {
      'id': 'synthetic-qoder',
      'app_type': 'codex',
      'settings_config': '{}',
      'meta': '{}',
    };
    await expectLater(
      read({
        'database': {
          'providers': [row, row],
        },
      }),
      fails('AmbiguousProvider'),
    );
    await expectLater(
      read({
        'database': {
          'providers': [
            {...row, 'app_type': 'claude'},
          ],
        },
      }),
      fails('UnsupportedCredentialSource'),
    );
  });
  test(
    'unsupported config strings and environment indirection do not read environment',
    () async {
      for (final settings in [
        {'config': 'api_key = "SYNTHETIC_PAT"'},
        {
          'config': {'api_key': 'SYNTHETIC_PAT'},
        },
        {
          'env': {'OPENAI_API_KEY': ''},
        },
        {'apiKey': 123},
        {'apiKey': '\$SECRET_ENV'},
        {'apiKey': 'SYNTHETIC\nSECRET'},
      ]) {
        await expectLater(
          read(provider(settings: settings)),
          fails('UnsupportedCredentialSource'),
        );
      }
    },
  );
  test(
    'duplicate JSON keys are rejected in outer and nested string documents',
    () async {
      await source.writeAsString('{"id":"a","id":"synthetic-qoder"}');
      await expectLater(
        QoderPatImport.read(source, providerId: 'synthetic-qoder'),
        fails('InvalidImport'),
      );
      await expectLater(
        read({
          'database': {
            'providers': [
              {
                'id': 'synthetic-qoder',
                'app_type': 'codex',
                'settings_config': '{"apiKey":"A","apiKey":"B"}',
                'meta': '{"providerType":"qoder_sdk"}',
              },
            ],
          },
        }),
        fails('InvalidImport'),
      );
    },
  );
  test(
    'bounded strict UTF8 JSON does not leak file paths or contents in errors',
    () async {
      for (final bytes in [
        [0xff],
        utf8.encode('SYNTHETIC_SECRET'),
        List<int>.filled(1024 * 1024 + 1, 0x20),
      ]) {
        await source.writeAsBytes(bytes);
        await expectLater(
          QoderPatImport.read(source, providerId: 'synthetic-qoder'),
          fails('InvalidImport'),
        );
      }
      await source.delete();
      await expectLater(
        QoderPatImport.read(source, providerId: 'synthetic-qoder'),
        fails('ImportUnavailable'),
      );
    },
  );
  test(
    'symlink and directory input are refused without changing source',
    () async {
      await source.writeAsString(jsonEncode(provider()));
      final alias = Link('${temp.path}/alias.json');
      await alias.create(source.path);
      await expectLater(
        QoderPatImport.read(File(alias.path), providerId: 'synthetic-qoder'),
        fails('ImportUnavailable'),
      );
      await expectLater(
        QoderPatImport.read(File(temp.path), providerId: 'synthetic-qoder'),
        fails('ImportUnavailable'),
      );
      expect(jsonDecode(await source.readAsString()), provider());
    },
  );
  test(
    'export row identity includes app_type so another app may reuse the id',
    () async {
      final candidate = await read({
        'database': {
          'providers': [
            {
              'id': 'synthetic-qoder',
              'app_type': 'claude',
              'settings_config': 'UNRELATED',
              'meta': '{}',
            },
            {
              'id': 'synthetic-qoder',
              'app_type': 'codex',
              'settings_config': '{"apiKey":"SYNTHETIC_PAT"}',
              'meta': '{"providerType":"qoder_sdk"}',
            },
          ],
        },
      });
      expect(candidate.useForVerification((v) => v), 'SYNTHETIC_PAT');
    },
  );
  test(
    'explicit null owner is not equivalent to the missing default owner',
    () async {
      await expectLater(
        read(
          provider(
            meta: {
              'providerType': 'qoder_sdk',
              'authBinding': {'source': null},
            },
          ),
        ),
        fails('UnsupportedCredentialSource'),
      );
      expect(
        (await read(
          provider(meta: {'providerType': 'qoder_sdk', 'authBinding': {}}),
        )).providerId,
        'synthetic-qoder',
      );
    },
  );
  test(
    'a selected path replaced with a symlink before open is rejected after read',
    () async {
      await source.writeAsString(
        jsonEncode(provider(settings: {'apiKey': 'SYNTHETIC_A'})),
      );
      final other = File('${temp.path}/not-selected.json');
      await other.writeAsString(
        jsonEncode(provider(settings: {'apiKey': 'SYNTHETIC_B'})),
      );
      await other.setLastModified(await source.lastModified());
      await expectLater(
        QoderPatImport.read(
          SwapAtOpen(source, other),
          providerId: 'synthetic-qoder',
        ),
        fails('InvalidImport'),
      );
      expect(await other.readAsString(), contains('SYNTHETIC_B'));
    },
  );
}
