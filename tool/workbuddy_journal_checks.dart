// Synthetic, direct-Dart checks only. No credentials, network, Flutter, or HOME
// overrides. The directory-sync seam is NOT evidence of native Mac durability.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/workbuddy_attempt_journal.dart';
import '../lib/workbuddy_claim.dart';

final subject = WorkBuddySubject('www.workbuddy.cn', 'synthetic-uid', 'owner-1');
final day = DateTime.utc(2026, 11, 4, 3);
void expect(bool value, String message) {
  if (!value) throw StateError(message);
}

WorkBuddyAttempt row({int revision = 0, WorkBuddySubject? who,
    String date = '2026-11-04', double before = 10,
    WorkBuddyState receipt = WorkBuddyState.unconfirmed, double? expected,
    WorkBuddyState settled = WorkBuddyState.unconfirmed, double? credited}) =>
  WorkBuddyAttempt(revision: revision, subject: who ?? subject, day: date,
    before: before, receipt: receipt, expected: expected,
    settled: settled, credited: credited);

Map<String, Object?> data(WorkBuddyAttempt r) => {
  'revision': r.revision, 'domain': r.subject.domain, 'uid': r.subject.uid,
  'generation': r.subject.generation, 'day': r.day, 'before': r.before,
  'receipt': r.receipt.name, 'expected': r.expected,
  'settled': r.settled.name, 'credited': r.credited,
};

class Fixture {
  final Directory root;
  bool live = true;
  int syncs = 0;
  Future<void> Function()? onSync;
  Fixture(this.root);
  File get file => File('${root.path}/workbuddy-intents.jsonl');
  WorkBuddyAttemptJournal open() => WorkBuddyAttemptJournal(root,
    syncDirectory: () async { syncs++; await onSync?.call(); },
    isCurrent: (_) => live);
  Future<void> raw(List<Map<String, Object?>> rows) => file.writeAsString(
    rows.map(jsonEncode).join('\n') + '\n', flush: true);
}

class Transport implements WorkBuddyTransport {
  int posts = 0, reads = 0;
  bool loseReply = false;
  final WorkBuddyAttemptStore store;
  Transport(this.store);
  @override
  Future<WorkBuddyObservation> observe(WorkBuddySubject who) async {
    reads++;
    return WorkBuddyObservation(who, {'code': 0, 'data': {
      'active': true, 'today_checked_in': posts > 0,
    }}, posts > 0 ? 30 : 10);
  }
  @override
  Future<Map<String, Object?>> claim(WorkBuddySubject who) async {
    final intent = await store.read(who.key);
    expect(intent != null && intent.settled == WorkBuddyState.unconfirmed,
      'POST without persisted intent');
    posts++;
    if (loseReply) throw StateError('synthetic dropped response');
    return {'code': 0, 'data': {'credit': 20}};
  }
}

Future<void> rejects(FutureOr<Object?> Function() action, {String? code}) async {
  try { await action(); }
  on WorkBuddyFailure catch (e) {
    if (code != null) expect(e.code == code, 'expected $code, got ${e.code}');
    return;
  }
  throw StateError('expected closed failure');
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == 'process-read') {
    final journal = WorkBuddyAttemptJournal(Directory(args[1]),
      syncDirectory: () async {}, isCurrent: (_) => true);
    stdout.writeln((await journal.read(subject.key))?.revision);
    return;
  }
  if (args.isNotEmpty && args.first == 'process-lost-receipt') {
    final journal = WorkBuddyAttemptJournal(Directory(args[1]),
      syncDirectory: () async {}, isCurrent: (_) => true);
    final transport = Transport(journal)..loseReply = true;
    final result = await WorkBuddyClaimCore(journal, transport, () => day,
      isCurrent: (_) => true).claim(subject);
    stdout.writeln('${transport.posts}:${result.state.name}');
    return;
  }
  if (args.isNotEmpty && args.first == 'process-lock-probe') {
    final journal = WorkBuddyAttemptJournal(Directory(args[1]),
      syncDirectory: () async {}, isCurrent: (_) => true);
    try { await journal.read(subject.key); stdout.writeln('unlocked'); }
    on WorkBuddyFailure catch (error) { stdout.writeln(error.code); }
    return;
  }
  var pass = 0, fail = 0;
  Future<void> check(String name, Future<void> Function(Fixture) body) async {
    if (args.isNotEmpty && !name.contains(args.first)) return;
    final root = await Directory.systemTemp.createTemp('workbuddy-journal-checks-');
    try {
      // This runtime creates synthetic temporary directories with 0755.
      // Tighten only our new disposable fixture, never any user directory.
      final mode = await Process.run('/bin/chmod', ['700', root.path]);
      expect(mode.exitCode == 0, 'fixture private directory setup');
      await body(Fixture(root));
      pass++;
      stdout.writeln('PASS $name');
    } catch (e) {
      fail++;
      stdout.writeln('FAIL $name: $e');
    } finally { await root.delete(recursive: true); }
  }

  await check('missing file is initial empty setup; exact filename', (f) async {
    expect(await f.open().read(subject.key) == null, 'initial row');
    expect(await f.file.exists(), 'separate filename');
    expect((await f.root.list().toList()).length == 1, 'unexpected files');
  });
  await check('intent is flushed and read back before sync acknowledgment', (f) async {
    f.onSync = () async {
      final d = jsonDecode((await f.file.readAsString()).trim()) as Map;
      expect(d['revision'] == 0 && d['receipt'] == 'unconfirmed', 'sync before row');
    };
    expect(await f.open().compareAndSet(subject.key, null, row()), 'intent rejected');
    expect(f.syncs == 1, 'missing sync');
    expect((await f.open().read(subject.key))?.before == 10, 'reopen lost intent');
  });
  await check('separate Dart process reopens persisted intent', (f) async {
    await f.open().compareAndSet(subject.key, null, row());
    final result = await Process.run(Platform.resolvedExecutable,
      [Platform.script.toFilePath(), 'process-read', f.root.path]);
    expect(result.exitCode == 0 && result.stdout.toString().trim() == '0',
      'process restart failed: ${result.stdout} ${result.stderr}');
  });
  await check('child persists lost receipt; restarted owner generation cannot POST', (f) async {
    final child = await Process.run(Platform.resolvedExecutable,
      [Platform.script.toFilePath(), 'process-lost-receipt', f.root.path]);
    expect(child.exitCode == 0 && child.stdout.toString().trim() == '1:unconfirmed',
      'child did not persist unknown attempt: ${child.stdout} ${child.stderr}');
    final reopened = f.open();
    expect((await reopened.read(subject.key))?.revision == 0, 'child intent missing');
    final transport = Transport(reopened);
    final changed = WorkBuddySubject(subject.domain, subject.uid, 'new-process-owner');
    await rejects(() => WorkBuddyClaimCore(reopened, transport, () => day,
      isCurrent: (_) => true).claim(changed), code: 'GenerationChanged');
    expect(transport.posts == 0 && transport.reads == 0, 'restart dispatched');
  });
  await check('revision CAS conflict leaves original bytes unchanged', (f) async {
    final store = f.open();
    await store.compareAndSet(subject.key, null, row());
    final saved = await f.file.readAsString();
    expect(!await f.open().compareAndSet(subject.key, null, row()), 'duplicate CAS');
    expect(await f.file.readAsString() == saved, 'conflict changed bytes');
  });
  await check('same-isolate guard covers separate journal objects', (f) async {
    final entered = Completer<void>(), release = Completer<void>();
    f.onSync = () async { entered.complete(); await release.future; };
    final pending = f.open().compareAndSet(subject.key, null, row());
    await entered.future;
    try {
      await rejects(() => f.open().read(subject.key), code: 'JournalBusy');
    } finally { release.complete(); }
    expect(await pending, 'first writer failed');
  });
  await check('POSIX journal lock excludes a competing Dart process', (f) async {
    final entered = Completer<void>(), release = Completer<void>();
    f.onSync = () async { entered.complete(); await release.future; };
    final pending = f.open().compareAndSet(subject.key, null, row());
    await entered.future;
    try {
      final result = await Process.run(Platform.resolvedExecutable,
        [Platform.script.toFilePath(), 'process-lock-probe', f.root.path]);
      expect(result.exitCode == 0 && result.stdout.toString().trim() == 'JournalBusy',
        'competing process bypassed lock: ${result.stdout} ${result.stderr}');
    } finally { release.complete(); }
    expect(await pending, 'owning write failed');
  });
  await check('revoked lifecycle before append never writes', (f) async {
    f.live = false;
    expect(!await f.open().compareAndSet(subject.key, null, row()), 'stale write');
    expect(await f.file.readAsString() == '', 'stale row persisted');
  });
  await check('revoked lifecycle during sync preserves intent and prevents POST', (f) async {
    final store = f.open(), transport = Transport(f.open());
    f.onSync = () async { f.live = false; };
    final core = WorkBuddyClaimCore(store, transport, () => day,
      isCurrent: (_) => f.live);
    final result = await core.claim(subject);
    expect(result.state == WorkBuddyState.unconfirmed && transport.posts == 0,
      'revoked commit permitted POST');
    expect((await f.open().read(subject.key))?.revision == 0, 'lost uncertain intent');
  });
  await check('sync exception preserves intent and prevents POST on reopen', (f) async {
    final transport = Transport(f.open());
    f.onSync = () async { throw StateError('synthetic sync failure'); };
    await rejects(() => WorkBuddyClaimCore(f.open(), transport, () => day,
      isCurrent: (_) => true).claim(subject));
    expect(transport.posts == 0, 'POST after sync error');
    f.onSync = null;
    final retry = Transport(f.open());
    final recovered = await WorkBuddyClaimCore(f.open(), retry, () => day,
      isCurrent: (_) => true).claim(subject);
    expect(recovered.state == WorkBuddyState.unconfirmed && retry.posts == 0,
      'replayed uncertain commit');
    expect((await f.open().read(subject.key))?.revision == 0, 'intent removed');
  });
  await check('lost receipt then re-created core never replays POST', (f) async {
    final first = Transport(f.open())..loseReply = true;
    final result = await WorkBuddyClaimCore(f.open(), first, () => day,
      isCurrent: (_) => true).claim(subject);
    expect(first.posts == 1 && result.state == WorkBuddyState.unconfirmed,
      'lost receipt result');
    final second = Transport(f.open());
    final reopened = await WorkBuddyClaimCore(f.open(), second, () => day,
      isCurrent: (_) => true).claim(subject);
    expect(second.posts == 0 && reopened.state == WorkBuddyState.unconfirmed,
      're-created core replayed');
  });
  await check('unresolved generation change blocks all new sends', (f) async {
    await f.open().compareAndSet(subject.key, null, row());
    final changed = WorkBuddySubject(subject.domain, subject.uid, 'owner-2');
    final transport = Transport(f.open());
    await rejects(() => WorkBuddyClaimCore(f.open(), transport, () => day,
      isCurrent: (_) => true).claim(changed), code: 'GenerationChanged');
    expect(transport.posts == 0 && transport.reads == 0, 'new generation sent');
    await rejects(() => f.open().compareAndSet(subject.key, 0,
      row(revision: 1, who: changed)));
  });
  await check('unresolved old day blocks replay and replacement row', (f) async {
    await f.open().compareAndSet(subject.key, null, row());
    final transport = Transport(f.open());
    final result = await WorkBuddyClaimCore(f.open(), transport,
      () => day.add(const Duration(days: 1)), isCurrent: (_) => true).claim(subject);
    expect(result.state == WorkBuddyState.unconfirmed && transport.posts == 0 &&
      transport.reads == 0, 'old day replayed');
    await rejects(() => f.open().compareAndSet(subject.key, 0,
      row(revision: 1, date: '2026-11-05')));
  });
  await check('receipt, settlement, same-day dedupe, next-day new generation', (f) async {
    final transport = Transport(f.open());
    final result = await WorkBuddyClaimCore(f.open(), transport, () => day,
      isCurrent: (_) => true).claim(subject);
    expect(result.state == WorkBuddyState.claimed && result.credited == 20 &&
      transport.posts == 1, 'settlement');
    final stored = (await f.open().read(subject.key))!;
    expect(stored.revision == 2 && stored.credited == 20, 'settlement not stored');
    final duplicate = Transport(f.open());
    final same = await WorkBuddyClaimCore(f.open(), duplicate, () => day,
      isCurrent: (_) => true).claim(subject);
    expect(same.state == WorkBuddyState.alreadyClaimed && duplicate.posts == 0,
      'same-day duplicate');
    final newer = WorkBuddySubject(subject.domain, subject.uid, 'owner-2');
    final next = Transport(f.open());
    final tomorrow = await WorkBuddyClaimCore(f.open(), next,
      () => day.add(const Duration(days: 1)), isCurrent: (_) => true).claim(newer);
    expect(tomorrow.state == WorkBuddyState.claimed && next.posts == 1 &&
      (await f.open().read(subject.key))?.revision == 5, 'next-day path blocked');
  });
  await check('settled non-credit receipt allows next-day intent', (f) async {
    final store = f.open();
    await store.compareAndSet(subject.key, null, row());
    await store.compareAndSet(subject.key, 0,
      row(revision: 1, receipt: WorkBuddyState.unavailable));
    await store.compareAndSet(subject.key, 1,
      row(revision: 2, receipt: WorkBuddyState.unavailable,
        settled: WorkBuddyState.unavailable));
    expect(await store.compareAndSet(subject.key, 2,
      row(revision: 3, date: '2026-11-05')), 'next-day intent');
  });
  await check('strict log contains only noncredential attempt fields', (f) async {
    await f.open().compareAndSet(subject.key, null, row());
    final raw = await f.file.readAsString();
    final decoded = jsonDecode(raw.trim()) as Map;
    expect(decoded.keys.toSet().difference(data(row()).keys.toSet()).isEmpty &&
      decoded.length == data(row()).length, 'extra persisted field');
    for (final forbidden in ['token', 'password', 'authorization', 'cookie', 'secret']) {
      expect(!raw.toLowerCase().contains(forbidden), 'credential field in log');
    }
  });
  for (final kind in ['partial', 'empty-line', 'malformed', 'bad-utf8',
      'extra-secret-field', 'missing-field', 'duplicate-field', 'invalid-day',
      'invalid-state', 'invalid-number', 'fractional-revision']) {
    await check('corrupt $kind fails closed without changing journal', (f) async {
      final good = '${jsonEncode(data(row()))}\n';
      final changed = data(row());
      switch (kind) {
        case 'partial': await f.file.writeAsString('$good{"revision":');
        case 'empty-line': await f.file.writeAsString('$good\n');
        case 'malformed': await f.file.writeAsString('$good{bad}\n');
        case 'bad-utf8': await f.file.writeAsBytes([...utf8.encode(good), 255, 10]);
        case 'extra-secret-field': changed['token'] = 'synthetic-only'; await f.raw([changed]);
        case 'missing-field': changed.remove('expected'); await f.raw([changed]);
        case 'duplicate-field': await f.file.writeAsString('${good.trim().substring(0, good.trim().length - 1)},"uid":"synthetic-uid"}\n');
        case 'invalid-day': changed['day'] = '2026-02-30'; await f.raw([changed]);
        case 'invalid-state': changed['receipt'] = 'available'; await f.raw([changed]);
        case 'invalid-number': changed['before'] = -1; await f.raw([changed]);
        case 'fractional-revision': changed['revision'] = 0.5; await f.raw([changed]);
      }
      final saved = await f.file.readAsBytes();
      await rejects(() => f.open().read(subject.key), code: 'JournalCorrupt');
      await rejects(() => f.open().compareAndSet(subject.key, null, row()));
      expect(base64Encode(await f.file.readAsBytes()) == base64Encode(saved),
        'corrupt bytes reset or trimmed');
    });
  }
  await check('all historical rows validated, not just newest row', (f) async {
    final bad = data(row())..['token'] = 'synthetic-only';
    await f.raw([bad, data(row())]);
    await rejects(() => f.open().read(subject.key), code: 'JournalCorrupt');
  });
  await check('cross-subject corruption blocks whole owner', (f) async {
    final other = WorkBuddySubject(subject.domain, 'other-synthetic', 'owner-1');
    await f.raw([data(row()), data(row(revision: 2, who: other))]);
    await rejects(() => f.open().read(subject.key), code: 'JournalCorrupt');
  });
  await check('historical baseline rewrite is rejected', (f) async {
    await f.raw([data(row()), data(row(revision: 1, before: 99))]);
    await rejects(() => f.open().read(subject.key), code: 'JournalCorrupt');
  });
  await check('historical receipt cannot be erased or changed', (f) async {
    await f.raw([data(row()), data(row(revision: 1,
      receipt: WorkBuddyState.claimed, expected: 20)), data(row(revision: 2))]);
    await rejects(() => f.open().read(subject.key), code: 'JournalCorrupt');
  });
  await check('historical revision gaps and duplicate revisions are rejected', (f) async {
    for (final revision in [0, 2]) {
      await f.raw([data(row()), data(row(revision: revision))]);
      await rejects(() => f.open().read(subject.key), code: 'JournalCorrupt');
    }
  });
  await check('settled attempts cannot restart on the same or previous day', (f) async {
    final store = f.open();
    await store.compareAndSet(subject.key, null, row());
    await store.compareAndSet(subject.key, 0,
      row(revision: 1, receipt: WorkBuddyState.alreadyClaimed));
    await store.compareAndSet(subject.key, 1,
      row(revision: 2, receipt: WorkBuddyState.alreadyClaimed,
        settled: WorkBuddyState.alreadyClaimed));
    final saved = await f.file.readAsString();
    for (final date in ['2026-11-04', '2026-11-03']) {
      await rejects(() => store.compareAndSet(subject.key, 2,
        row(revision: 3, date: date)));
    }
    expect(await f.file.readAsString() == saved, 'settled history changed');
  });
  await check('same UID across supported domains remains independently scoped', (f) async {
    final other = WorkBuddySubject('www.codebuddy.cn', subject.uid, 'owner-1');
    final store = f.open();
    expect(await store.compareAndSet(subject.key, null, row()), 'first domain');
    expect(await store.compareAndSet(other.key, null, row(who: other)), 'second domain');
    expect((await store.read(subject.key))?.subject.domain == subject.domain &&
      (await store.read(other.key))?.subject.domain == other.domain, 'domains collided');
  });
  await check('settlement requires a previous matching receipt', (f) async {
    await f.open().compareAndSet(subject.key, null, row());
    await rejects(() => f.open().compareAndSet(subject.key, 0,
      row(revision: 1, receipt: WorkBuddyState.claimed, expected: 20,
        settled: WorkBuddyState.claimed, credited: 20)));
  });
  await check('credit settlement must equal positive expected credit', (f) async {
    await f.open().compareAndSet(subject.key, null, row());
    await f.open().compareAndSet(subject.key, 0,
      row(revision: 1, receipt: WorkBuddyState.claimed, expected: 20));
    await rejects(() => f.open().compareAndSet(subject.key, 1,
      row(revision: 2, receipt: WorkBuddyState.claimed, expected: 20,
        settled: WorkBuddyState.claimed, credited: 19)));
  });
  await check('key, revision and nonfinite input fail before append', (f) async {
    await rejects(() => f.open().read('["www.workbuddy.cn", "synthetic-uid"]'));
    await rejects(() => f.open().compareAndSet(subject.key, null, row(revision: 1)));
    await rejects(() => f.open().compareAndSet(subject.key, null, row(before: double.nan)));
    await rejects(() => f.open().compareAndSet(subject.key, null, row(before: double.infinity)));
    await rejects(() => f.open().compareAndSet(subject.key, null,
      row(who: WorkBuddySubject(subject.domain, subject.uid, 'bad\ngeneration'))));
    expect(!await f.file.exists() || await f.file.length() == 0, 'invalid input appended');
  });
  await check('symlink journal is rejected without changing its target', (f) async {
    final target = File('${f.root.path}/synthetic-target');
    await target.writeAsString('synthetic');
    await Link(f.file.path).create(target.path);
    await rejects(() => f.open().read(subject.key));
    expect(await target.readAsString() == 'synthetic', 'symlink target changed');
  });
  await check('missing root fails closed, never creates directory', (f) async {
    final missing = Directory('${f.root.path}/missing');
    await rejects(() => WorkBuddyAttemptJournal(missing,
      syncDirectory: () async {}, isCurrent: (_) => true).read(subject.key));
    expect(!await missing.exists(), 'root created');
  });
  stdout.writeln('$pass passed, $fail failed');
  stdout.writeln('Synthetic directory-sync callback only; native Mac durability not tested.');
  exitCode = fail == 0 ? 0 : 1;
}
