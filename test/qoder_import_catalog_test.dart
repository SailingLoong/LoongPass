import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/qoder_claim.dart';
import '../lib/qoder_pat_import.dart';

void main() {
  late Directory temp;
  late File file;
  Map<String, Object?> row(
    String id, {
    String app = 'codex',
    String kind = 'qoder_sdk',
  }) => {
    'id': id,
    'app_type': app,
    'settings_config': jsonEncode({'apiKey': 'SYNTHETIC_PAT'}),
    'meta': jsonEncode({'providerType': kind}),
  };
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('loongpass-catalog-');
    file = File('${temp.path}/selected.json');
  });
  tearDown(() async => temp.delete(recursive: true));
  test(
    'single Provider JSON exposes only its safe ID, never the credential',
    () async {
      await file.writeAsString(
        jsonEncode({
          'id': 'selected',
          'settingsConfig': {'apiKey': 'SYNTHETIC_PAT'},
          'meta': {'providerType': 'qoder_sdk'},
        }),
      );
      expect(await QoderPatImport.listProviderIds(file), ['selected']);
    },
  );
  test(
    'export catalog filters by codex and Qoder and preserves explicit selection',
    () async {
      await file.writeAsString(
        jsonEncode({
          'database': {
            'providers': [
              row('q1'),
              row('q2'),
              row('q1', app: 'claude'),
              row('other', kind: 'other'),
            ],
          },
        }),
      );
      expect(await QoderPatImport.listProviderIds(file), ['q1', 'q2']);
      expect(
        (await QoderPatImport.read(file, providerId: 'q2')).providerId,
        'q2',
      );
    },
  );
  test(
    'duplicate target identity is not hidden by catalog deduplication',
    () async {
      await file.writeAsString(
        jsonEncode({
          'database': {
            'providers': [row('q1'), row('q1')],
          },
        }),
      );
      await expectLater(
        QoderPatImport.listProviderIds(file),
        throwsA(
          isA<QoderFailure>().having(
            (e) => e.code,
            'code',
            'AmbiguousProvider',
          ),
        ),
      );
    },
  );
  test(
    'unsupported or malformed entries do not become importable accounts',
    () async {
      for (final data in [
        {
          'database': {
            'providers': [row('other', kind: 'other')],
          },
        },
        {
          'id': 'bad/id',
          'settingsConfig': {},
          'meta': {'providerType': 'qoder_sdk'},
        },
        {
          'database': {
            'providers': [
              {'id': 'bad', 'app_type': 'codex', 'meta': 'broken'},
            ],
          },
        },
      ]) {
        await file.writeAsString(jsonEncode(data));
        await expectLater(
          QoderPatImport.listProviderIds(file),
          throwsA(isA<QoderFailure>()),
        );
      }
    },
  );
  test(
    'catalog shares strict bounded file parsing and does not write side files',
    () async {
      await file.writeAsString('{"database":{},"database":{}}');
      await expectLater(
        QoderPatImport.listProviderIds(file),
        throwsA(isA<QoderFailure>()),
      );
      expect((await temp.list().toList()).length, 1);
    },
  );
  test(
    'unrelated null metadata and managed accounts do not hide a valid local candidate',
    () async {
      await file.writeAsString(
        jsonEncode({
          'database': {
            'providers': [
              row('valid'),
              {...row('unrelated'), 'meta': null},
              {
                ...row('managed'),
                'meta': jsonEncode({
                  'providerType': 'qoder_sdk',
                  'authBinding': {'source': 'managed_account'},
                }),
              },
            ],
          },
        }),
      );
      expect(await QoderPatImport.listProviderIds(file), ['valid']);
    },
  );
  test(
    'duplicate codex identity is refused even when only one row names Qoder',
    () async {
      await file.writeAsString(
        jsonEncode({
          'database': {
            'providers': [row('same'), row('same', kind: 'other')],
          },
        }),
      );
      await expectLater(
        QoderPatImport.listProviderIds(file),
        throwsA(
          isA<QoderFailure>().having(
            (e) => e.code,
            'code',
            'AmbiguousProvider',
          ),
        ),
      );
    },
  );
}
