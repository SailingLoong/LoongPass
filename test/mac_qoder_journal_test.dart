import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/mac_qoder_journal.dart';
import '../lib/qoder_claim.dart';
import 'qoder_claim_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.sailingloong.loongpass/files');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late List<String> calls;
  bool failSync = false;
  Object? selection;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('loongpass-journal-bridge-');
    root = Directory(await root.resolveSymbolicLinks());
    expect((await Process.run('chmod', ['700', root.path])).exitCode, 0);
    calls = [];
    failSync = false;
    selection = root.path;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      expect(call.arguments, isNull); // Never accepts arbitrary native paths.
      if (call.method == 'prepareQoderJournal') return selection;
      if (call.method == 'syncQoderJournal' && failSync)
        throw PlatformException(code: 'failure', message: 'SYNTHETIC_PRIVATE');
      return null;
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });
  test(
    'native path and directory-sync acknowledgement are used before first POST',
    () async {
      final journal = await MacQoderJournal.open();
      expect(
        await journal.perform(fixtures.listing(), (r) async {
          expect(calls, ['prepareQoderJournal', 'syncQoderJournal']);
          expect(await File('${root.path}/qoder-intents.jsonl').exists(), true);
          return fixtures.reply(r);
        }),
        QoderOutcome.newlyClaimed,
      );
      expect(calls, [
        'prepareQoderJournal',
        'syncQoderJournal',
        'syncQoderJournal',
      ]);
    },
  );
  test(
    'native sync failure prevents POST and remains unresolved on reopen',
    () async {
      final journal = await MacQoderJournal.open();
      failSync = true;
      await expectLater(
        journal.perform(
          fixtures.listing(),
          (_) async => throw StateError('must not send'),
        ),
        throwsA(
          isA<QoderFailure>().having(
            (e) => e.code,
            'code',
            'PersistenceUnavailable',
          ),
        ),
      );
      failSync = false;
      expect(
        (await journal.latest(fixtures.identity))!.outcome,
        QoderOutcome.unknown,
      );
      expect(
        await journal.perform(fixtures.listing(), (request) async {
          expect(request.method, 'GET');
          return fixtures.reply(request);
        }),
        QoderOutcome.claimedDeltaUnknown,
      );
    },
  );
  test('invalid native path is a sanitized blocker', () async {
    selection = {'path': 'SYNTHETIC_PRIVATE'};
    await expectLater(
      MacQoderJournal.open(),
      throwsA(
        isA<QoderFailure>().having(
          (e) => e.code,
          'code',
          'NativeJournalUnavailable',
        ),
      ),
    );
  });
}
