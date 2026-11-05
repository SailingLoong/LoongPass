import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/qoder_account_flow.dart';
import '../lib/qoder_claim.dart';
import '../lib/qoder_journal.dart';
import '../lib/qoder_pat_import.dart';
import 'qoder_claim_test.dart' as f;

void main() {
  late Directory root;
  late QoderPatCandidate candidate;
  late QoderAttemptJournal journal;
  setUp(() async {
    root = Directory(
      await (await Directory.systemTemp.createTemp(
        'loongpass-flow-',
      )).resolveSymbolicLinks(),
    );
    expect((await Process.run('chmod', ['700', root.path])).exitCode, 0);
    final file = File('${root.path}/source.json');
    await file.writeAsString(
      jsonEncode({
        'id': f.identity.providerId,
        'settingsConfig': {'apiKey': 'SYNTHETIC_PAT'},
        'meta': {'providerType': 'qoder_sdk'},
      }),
    );
    candidate = await QoderPatImport.read(
      file,
      providerId: f.identity.providerId,
    );
    journal = QoderAttemptJournal(root, syncDirectory: () async {});
  });
  tearDown(() async => root.delete(recursive: true));
  QoderAccountFlow make(
    Future<QoderSession> Function(QoderPatCandidate)? authenticate,
  ) => QoderAccountFlow(
    authenticate: authenticate,
    openJournal: () async => journal,
  );
  test(
    'production default imports as unverified and never opens journal for a claim',
    () async {
      final flow = QoderAccountFlow(
        openJournal: () async => throw StateError('must not open'),
      );
      addTearDown(flow.dispose);
      flow.put(candidate);
      expect(flow.accounts.single.providerId, f.identity.providerId);
      expect(flow.accounts.single.status, 'unverified');
      expect(flow.canClaim(candidate.providerId), false);
      await flow.claim(candidate.providerId);
      expect(flow.accounts.single.status, 'unavailable');
      expect(await File('${root.path}/qoder-intents.jsonl').exists(), false);
    },
  );
  test(
    'synthetic gateway connects actual import, journal, protocol and status',
    () async {
      var posts = 0;
      final flow = make((c) async {
        expect(identical(c, candidate), true);
        return QoderSession(f.listing(), (r) async {
          expect(r.method, 'POST');
          posts++;
          return f.reply(r);
        });
      });
      addTearDown(flow.dispose);
      flow.put(candidate);
      await flow.claim(candidate.providerId);
      expect(flow.accounts.single.status, 'claimed');
      expect(posts, 1);
      expect(flow.busy, false);
      expect(
        (await journal.latest(f.identity))!.outcome,
        QoderOutcome.newlyClaimed,
      );
    },
  );
  test(
    'unknown result is not success and another click reconciles only GET',
    () async {
      final methods = <String>[];
      final flow = make(
        (_) async => QoderSession(f.listing(), (r) async {
          methods.add(r.method);
          if (r.method == 'POST') throw StateError('lost');
          return f.reply(r);
        }),
      );
      addTearDown(flow.dispose);
      flow.put(candidate);
      await flow.claim(candidate.providerId);
      expect(flow.accounts.single.status, 'unknown');
      await flow.claim(candidate.providerId);
      expect(methods, ['POST', 'GET']);
      expect(flow.accounts.single.status, 'confirmed');
    },
  );
  test(
    'duplicate click and replacement while authentication is pending do not dispatch twice',
    () async {
      final gate = Completer<QoderSession>();
      var auths = 0;
      var posts = 0;
      final flow = make((_) async {
        auths++;
        return gate.future;
      });
      addTearDown(flow.dispose);
      flow.put(candidate);
      final pending = flow.claim(candidate.providerId);
      expect(flow.busy, true);
      await flow.claim(candidate.providerId);
      expect(() => flow.put(candidate), throwsA(isA<QoderFailure>()));
      expect(auths, 1);
      gate.complete(
        QoderSession(f.listing(), (r) async {
          posts++;
          return f.reply(r);
        }),
      );
      await pending;
      expect(posts, 1);
      expect(flow.busy, false);
    },
  );
  test(
    'reimporting the same account does not erase durable settled history',
    () async {
      var posts = 0;
      final flow = make(
        (_) async => QoderSession(f.listing(), (r) async {
          posts++;
          return f.reply(r);
        }),
      );
      addTearDown(flow.dispose);
      flow.put(candidate);
      await flow.claim(candidate.providerId);
      flow.put(candidate);
      expect(flow.accounts.length, 1);
      expect(flow.accounts.single.status, 'unverified');
      await flow.claim(candidate.providerId);
      expect(posts, 1);
      expect(flow.accounts.single.status, 'already');
    },
  );
  test(
    'mismatched provider or region cannot enter the journal or send',
    () async {
      for (final id in [
        const QoderIdentity('wrong', 'synthetic-uid', 'g'),
        const QoderIdentity(
          'synthetic-provider',
          'synthetic-uid',
          'g',
          region: 'china',
        ),
      ]) {
        final flow = QoderAccountFlow(
          authenticate: (_) async => QoderSession(
            f.listing(id: id),
            (_) async => throw StateError('must not send'),
          ),
          openJournal: () async => throw StateError('must not open'),
        );
        flow.put(candidate);
        await flow.claim(candidate.providerId);
        expect(flow.accounts.single.status, 'verification');
        flow.dispose();
      }
    },
  );
  test(
    'authentication or device failure has no persisted intent and no secret error text',
    () async {
      final flow = make((_) async => throw StateError('SYNTHETIC_SECRET'));
      addTearDown(flow.dispose);
      flow.put(candidate);
      await flow.claim(candidate.providerId);
      expect(flow.accounts.single.status, 'verification');
      expect(await File('${root.path}/qoder-intents.jsonl').exists(), false);
    },
  );
  test(
    'disposing during authentication does not start a later journal or request',
    () async {
      final gate = Completer<QoderSession>();
      final flow = QoderAccountFlow(
        authenticate: (_) async => gate.future,
        openJournal: () async => throw StateError('must not open'),
      );
      flow.put(candidate);
      final pending = flow.claim(candidate.providerId);
      flow.dispose();
      gate.complete(
        QoderSession(
          f.listing(),
          (_) async => throw StateError('must not send'),
        ),
      );
      await pending;
      expect(await File('${root.path}/qoder-intents.jsonl').exists(), false);
    },
  );
  test(
    'manual actions serialize accounts instead of racing one shared journal',
    () async {
      final otherFile = File('${root.path}/other.json');
      await otherFile.writeAsString(
        jsonEncode({
          'id': 'second',
          'settingsConfig': {'apiKey': 'SYNTHETIC_SECOND'},
          'meta': {'providerType': 'qoder_sdk'},
        }),
      );
      final other = await QoderPatImport.read(otherFile, providerId: 'second');
      final gate = Completer<QoderSession>();
      var calls = 0;
      final flow = make((_) async {
        calls++;
        return gate.future;
      });
      addTearDown(flow.dispose);
      flow.put(candidate);
      flow.put(other);
      final pending = flow.claim(candidate.providerId);
      expect(flow.canClaim(other.providerId), false);
      await flow.claim(other.providerId);
      expect(calls, 1);
      gate.complete(QoderSession(f.listing(), (r) async => f.reply(r)));
      await pending;
      expect(flow.canClaim(other.providerId), true);
    },
  );

  test(
    'disposing after durable intent starts prevents a later first POST',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var sends = 0;
      final paused = QoderAttemptJournal(
        root,
        syncDirectory: () async {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        },
      );
      final flow = QoderAccountFlow(
        authenticate: (_) async => QoderSession(f.listing(), (r) async {
          sends++;
          return f.reply(r);
        }),
        openJournal: () async => paused,
      );
      flow.put(candidate);
      final pending = flow.claim(candidate.providerId);
      await entered.future;
      flow.dispose();
      release.complete();
      await pending;
      expect(sends, 0);
      expect((await journal.latest(f.identity))!.outcome, QoderOutcome.unknown);
    },
  );
}
