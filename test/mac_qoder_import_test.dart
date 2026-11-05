import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/mac_qoder_import.dart';
import '../lib/qoder_claim.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.sailingloong.loongpass/files');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temp;
  late File file;
  late List<String> calls;
  Object? selection;
  bool failRelease = false;
  const importer = MacQoderImport();
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('loongpass-picker-');
    file = File('${temp.path}/selected.json');
    await file.writeAsString(
      jsonEncode({
        'id': 'synthetic-qoder',
        'settingsConfig': {'apiKey': 'SYNTHETIC_PAT'},
        'meta': {'providerType': 'qoder_sdk'},
      }),
    );
    calls = [];
    selection = file.path;
    failRelease = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.arguments, isNull);
      calls.add(call.method);
      if (call.method == 'chooseQoderImportSource') return selection;
      if (call.method == 'releaseSelectedSource' && failRelease)
        throw PlatformException(code: 'private', message: 'SYNTHETIC_SECRET');
      return null;
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await temp.delete(recursive: true);
  });
  Matcher failure(String code) =>
      throwsA(isA<QoderFailure>().having((e) => e.code, 'code', code));
  test(
    'one selected provider auto imports and releases the native scope',
    () async {
      final result = await importer.select(
        (_) async => throw StateError('must not ask'),
      );
      expect(result!.providerId, 'synthetic-qoder');
      expect(calls, ['chooseQoderImportSource', 'releaseSelectedSource']);
      expect((await temp.list().toList()).length, 1);
    },
  );
  test(
    'multiple providers ask once and import only the selected candidate',
    () async {
      await file.writeAsString(
        jsonEncode({
          'database': {
            'providers': [
              for (final id in ['a', 'b'])
                {
                  'id': id,
                  'app_type': 'codex',
                  'settings_config': '{"apiKey":"SYNTHETIC_PAT"}',
                  'meta': '{"providerType":"qoder_sdk"}',
                },
            ],
          },
        }),
      );
      final result = await importer.select((ids) async {
        expect(ids, ['a', 'b']);
        return 'b';
      });
      expect(result!.providerId, 'b');
      expect(calls.last, 'releaseSelectedSource');
    },
  );
  test(
    'native cancellation has no unnecessary release or imported account',
    () async {
      selection = null;
      expect(await importer.select((_) async => 'unused'), isNull);
      expect(calls, ['chooseQoderImportSource']);
    },
  );
  test(
    'cancel choosing one provider still releases selected-file scope',
    () async {
      await file.writeAsString(
        jsonEncode({
          'database': {
            'providers': [
              for (final id in ['a', 'b'])
                {
                  'id': id,
                  'app_type': 'codex',
                  'settings_config': '{"apiKey":"SYNTHETIC_PAT"}',
                  'meta': '{"providerType":"qoder_sdk"}',
                },
            ],
          },
        }),
      );
      expect(await importer.select((_) async => null), isNull);
      expect(calls.last, 'releaseSelectedSource');
    },
  );
  test(
    'bad source and invalid native selection release and expose only fixed errors',
    () async {
      await file.writeAsString('SYNTHETIC_SECRET');
      await expectLater(
        importer.select((_) async => 'unused'),
        failure('InvalidImport'),
      );
      expect(calls.last, 'releaseSelectedSource');
      selection = {'secret': 'SYNTHETIC_SECRET'};
      await expectLater(
        importer.select((_) async => 'unused'),
        failure('InvalidSelection'),
      );
      expect(calls.last, 'releaseSelectedSource');
    },
  );
  test(
    'release failure prevents accepting a candidate and does not leak native details',
    () async {
      failRelease = true;
      await expectLater(
        importer.select((_) async => 'unused'),
        failure('NativeImportCleanupFailed'),
      );
    },
  );
  test('a selection not in the inspected catalog is rejected', () async {
    await file.writeAsString(
      jsonEncode({
        'database': {
          'providers': [
            for (final id in ['a', 'b'])
              {
                'id': id,
                'app_type': 'codex',
                'settings_config': '{"apiKey":"SYNTHETIC_PAT"}',
                'meta': '{"providerType":"qoder_sdk"}',
              },
          ],
        },
      }),
    );
    await expectLater(
      importer.select((_) async => 'unrelated'),
      failure('ProviderNotFound'),
    );
  });
}
