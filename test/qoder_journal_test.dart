@TestOn('!windows')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/qoder_claim.dart';
import '../lib/qoder_journal.dart';
import 'qoder_claim_test.dart' as fixtures;

void main() {
  late Directory root;
  late QoderAttemptJournal journal;
  var syncs = 0;
  Map<String, Object?> record({
    String uid = 'synthetic-uid',
    String provider = 'synthetic-provider',
    String generation = 'generation-1',
    int shift = 0,
  }) => {
    'providerId': provider,
    'uid': uid,
    'generation': generation,
    'region': 'international',
    'campaignId': 'synthetic-daily${shift == 0 ? '' : shift}',
    'campaignKey': 'synthetic-window$shift',
    'startAt': fixtures.nowSeconds - 100 + shift,
    'endAt': fixtures.nowSeconds + 3600 + shift,
  };
  Matcher fails(String code) =>
      throwsA(isA<QoderFailure>().having((e) => e.code, 'code', code));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('loongpass-journal-');
    root = Directory(await root.resolveSymbolicLinks());
    expect((await Process.run('chmod', ['700', root.path])).exitCode, 0);
    syncs = 0;
    journal = QoderAttemptJournal(
      root,
      syncDirectory: () async {
        syncs++;
      },
    );
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  test(
    'intent is written, flushed and directory-sync acknowledged before true',
    () async {
      expect(await journal.claim(record()), true);
      expect(syncs, 1);
      final entries = await root.list().toList();
      expect(entries, hasLength(1));
      expect(
        await File('${root.path}/qoder-intents.jsonl').readAsString(),
        contains('synthetic-uid'),
      );
      final reopened = QoderAttemptJournal(root, syncDirectory: () async {});
      final saved = await reopened.latest(fixtures.identity);
      expect(saved!.outcome, QoderOutcome.unknown);
      expect(saved.record, record());
      expect(await reopened.claim(record()), false);
    },
  );
  test(
    'provider deletion/recreation or credential rotation cannot reset dedup',
    () async {
      expect(await journal.claim(record()), true);
      expect(
        await journal.claim(
          record(provider: 'recreated', generation: 'generation-2'),
        ),
        false,
      );
      expect(syncs, 1);
    },
  );
  test('separate subjects are independent', () async {
    expect(await journal.claim(record()), true);
    expect(await journal.claim(record(uid: 'second')), true);
    expect(syncs, 2);
  });
  test(
    'unknown prior operation blocks all future windows for same subject',
    () async {
      await journal.claim(record());
      expect(await journal.claim(record(shift: 86400)), false);
      expect((await journal.latest(fixtures.identity))!.record, record());
    },
  );
  test(
    'known prior operation permits only a later non-overlapping window',
    () async {
      await journal.claim(record());
      await journal.complete(record(), QoderOutcome.newlyClaimed);
      expect(await journal.claim(record(shift: 100)), false);
      expect(await journal.claim(record(shift: 86400)), true);
    },
  );
  test(
    'completion is durable and cannot silently downgrade a known grant',
    () async {
      await journal.claim(record());
      await journal.complete(record(), QoderOutcome.newlyClaimed);
      await journal.complete(record(), QoderOutcome.claimedDeltaUnknown);
      expect(
        (await QoderAttemptJournal(
          root,
          syncDirectory: () async {},
        ).latest(fixtures.identity))!.outcome,
        QoderOutcome.newlyClaimed,
      );
      expect(syncs, 2);
    },
  );
  test('completion without matching intent is refused', () async {
    await expectLater(
      journal.complete(record(), QoderOutcome.newlyClaimed),
      fails('JournalConflict'),
    );
  });
  test(
    'partial final line blocks rather than discarding unknown intent',
    () async {
      await journal.claim(record());
      final file = File('${root.path}/qoder-intents.jsonl');
      await file.writeAsString('{"kind":"intent"', mode: FileMode.append);
      final before = await file.readAsBytes();
      await expectLater(
        journal.claim(record(shift: 86400)),
        fails('JournalCorrupt'),
      );
      expect(await file.readAsBytes(), before);
    },
  );
  test(
    'duplicate JSON keys and unrelated record fields are rejected',
    () async {
      final file = File('${root.path}/qoder-intents.jsonl');
      await file.writeAsString(
        '{"kind":"bad","kind":"intent","record":${jsonEncode(record())}}\n',
      );
      await expectLater(
        journal.latest(fixtures.identity),
        fails('JournalCorrupt'),
      );
      await file.delete();
      await expectLater(
        journal.claim({...record(), 'token': 'SYNTHETIC_NOT_ALLOWED'}),
        fails('InvalidRecord'),
      );
      expect(await file.exists(), false);
    },
  );
  test(
    'failed directory sync cannot grant POST and leaves a recoverable intent',
    () async {
      final failing = QoderAttemptJournal(
        root,
        syncDirectory: () async => throw StateError('SYNTHETIC_SECRET'),
      );
      await expectLater(failing.claim(record()), fails('JournalUnavailable'));
      expect(
        (await journal.latest(fixtures.identity))!.outcome,
        QoderOutcome.unknown,
      );
      expect(await journal.claim(record()), false);
    },
  );
  test('same-isolate parallel handles cannot both grant an intent', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final first = QoderAttemptJournal(
      root,
      syncDirectory: () async {
        entered.complete();
        await release.future;
      },
    );
    final pending = first.claim(record()).catchError((Object error) {
      if (!entered.isCompleted) entered.completeError(error);
      return false;
    });
    await entered.future;
    await expectLater(journal.claim(record()), fails('JournalBusy'));
    release.complete();
    expect(await pending, true);
    expect(await journal.claim(record()), false);
  });
  test('symlink journal and nonprivate roots are refused', () async {
    final outside = File('${root.path}/outside');
    await outside.writeAsString('unchanged');
    await Link('${root.path}/qoder-intents.jsonl').create(outside.path);
    await expectLater(journal.claim(record()), fails('JournalUnavailable'));
    expect(await outside.readAsString(), 'unchanged');
    final public = await Directory('${root.path}/public').create();
    if ((await public.stat()).mode & 0x3f != 0) {
      await expectLater(
        QoderAttemptJournal(public, syncDirectory: () async {}).claim(record()),
        fails('PrivateDirectoryRequired'),
      );
    }
  });
  test('protocol wrapper reopens unknown result only as reward GET', () async {
    var posts = 0;
    final result = await journal.perform(fixtures.listing(), (request) async {
      expect(request.method, 'POST');
      posts++;
      throw StateError('synthetic lost response');
    });
    expect(result, QoderOutcome.unknown);
    final reopened = QoderAttemptJournal(root, syncDirectory: () async {});
    expect(
      await reopened.perform(fixtures.listing(), (request) async {
        expect(request.method, 'GET');
        return fixtures.reply(request);
      }),
      QoderOutcome.claimedDeltaUnknown,
    );
    expect(posts, 1);
    expect(
      (await reopened.latest(fixtures.identity))!.outcome,
      QoderOutcome.claimedDeltaUnknown,
    );
  });
  test('known current campaign is not posted again after restart', () async {
    expect(
      await journal.perform(fixtures.listing(), (r) async => fixtures.reply(r)),
      QoderOutcome.newlyClaimed,
    );
    expect(
      await QoderAttemptJournal(root, syncDirectory: () async {}).perform(
        fixtures.listing(),
        (_) async => throw StateError('must not send'),
      ),
      QoderOutcome.alreadyClaimed,
    );
  });
  test(
    'OS lock blocks a second process and survives first-process restart',
    () async {
      final dart = Platform.environment['FLUTTER_ROOT'] == null
          ? '../toolchain/flutter/bin/cache/dart-sdk/bin/dart'
          : '${Platform.environment['FLUTTER_ROOT']}/bin/cache/dart-sdk/bin/dart';
      final owner = await Process.start(dart, [
        'tool/qoder_journal_process.dart',
        root.path,
        'hold',
      ]);
      final lines = StreamIterator(
        owner.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      try {
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 20)),
          true,
        );
        expect(lines.current, 'locked');
        final blocked = await Process.run(dart, [
          'tool/qoder_journal_process.dart',
          root.path,
          'try',
        ]);
        expect(blocked.exitCode, 0, reason: blocked.stderr.toString());
        expect(blocked.stdout.toString().trim(), 'JournalBusy');
        owner.stdin.writeln('release');
        await owner.stdin.flush();
        expect(await lines.moveNext(), true);
        expect(lines.current, 'granted');
        expect(await owner.exitCode, 0);
        final reopened = await Process.run(dart, [
          'tool/qoder_journal_process.dart',
          root.path,
          'try',
        ]);
        expect(reopened.exitCode, 0, reason: reopened.stderr.toString());
        expect(reopened.stdout.toString().trim(), 'duplicate');
      } finally {
        owner.kill();
        await lines.cancel();
      }
    },
  );
  test(
    'refreshed CLAIMED listing reports the durable settled outcome without sending',
    () async {
      await journal.perform(fixtures.listing(), (r) async => fixtures.reply(r));
      final response = fixtures.listing(
        body: {
          'uid': fixtures.identity.uid,
          'campaigns': [
            {...fixtures.row(), 'claimStatus': 'CLAIMED'},
          ],
        },
      );
      expect(
        await journal.perform(
          response,
          (_) async => throw StateError('must not send'),
        ),
        QoderOutcome.alreadyClaimed,
      );
    },
  );
  test(
    'a settled record cannot turn a malformed refreshed listing into success',
    () async {
      await journal.perform(fixtures.listing(), (r) async => fixtures.reply(r));
      final malformed = fixtures.listing(
        uri: Uri.parse('https://example.invalid/campaigns'),
        body: {
          'uid': fixtures.identity.uid,
          'campaigns': [
            {...fixtures.row(), 'claimStatus': 'CLAIMED'},
          ],
        },
      );
      await expectLater(
        journal.perform(
          malformed,
          (_) async => throw StateError('must not send'),
        ),
        fails('InvalidResponse'),
      );
    },
  );
  test(
    'a settled previous day still permits one later nonoverlapping campaign',
    () async {
      await journal.perform(fixtures.listing(), (r) async => fixtures.reply(r));
      final next = fixtures.now.add(const Duration(days: 1));
      final seconds = next.millisecondsSinceEpoch ~/ 1000;
      final listing = fixtures.listing(
        headers: {
          'Date': [HttpDate.format(next)],
        },
        body: {
          'uid': fixtures.identity.uid,
          'campaigns': [
            {
              ...fixtures.row(),
              'campaignId': 'synthetic-next',
              'campaignKey': 'synthetic-next-window',
              'startAt': seconds - 100,
              'endAt': seconds + 3600,
            },
          ],
        },
      );
      var sends = 0;
      expect(
        await journal.perform(listing, (r) async {
          expect(r.method, 'POST');
          sends++;
          return fixtures.reply(
            r,
            body: {
              ...fixtures.receipt(),
              'campaignId': 'synthetic-next',
              'campaignKey': 'synthetic-next-window',
              'claimedAt': next.toIso8601String(),
            },
          );
        }),
        QoderOutcome.newlyClaimed,
      );
      expect(sends, 1);
    },
  );
}
