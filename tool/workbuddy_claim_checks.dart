// Entire suite uses synthetic responses and an in-memory CAS store; no I/O/network.
import 'dart:async';
import 'dart:io';

import '../lib/workbuddy_claim.dart';

final subject = WorkBuddySubject(
  'www.workbuddy.cn',
  'synthetic-uid',
  'generation-1',
);
Map<String, Object?> status(bool checked, {bool active = true}) => {
  'code': 0,
  'data': {'active': active, 'today_checked_in': checked},
};
void expect(bool value, String message) {
  if (!value) throw StateError(message);
}

class MemoryStore implements WorkBuddyAttemptStore {
  final rows = <String, WorkBuddyAttempt>{};
  void Function()? onRead;
  bool fail = false;
  void Function(WorkBuddyAttempt)? onCas;
  final events = <String>[];
  @override
  Future<WorkBuddyAttempt?> read(String key) async {
    onRead?.call();
    return rows[key];
  }

  @override
  Future<bool> compareAndSet(
    String key,
    int? revision,
    WorkBuddyAttempt next,
  ) async {
    if (fail) throw const WorkBuddyFailure('StorageUnavailable');
    if (rows[key]?.revision != revision) return false;
    rows[key] = next;
    events.add('persist');
    onCas?.call(next);
    return true;
  }
}

class FakeTransport implements WorkBuddyTransport {
  final MemoryStore store;
  int posts = 0, reads = 0;
  Map<String, Object?> receipt = {
    'code': 0,
    'data': {'credit': 20},
  };
  final List<WorkBuddyObservation> observations = [];
  bool loseReply = false;
  int? failObserveAt;
  Future<void> Function()? onObserve;
  Future<void> Function()? beforePost;
  FakeTransport(this.store) {
    observations.addAll([
      WorkBuddyObservation(subject, status(false), 10),
      WorkBuddyObservation(subject, status(true), 30),
    ]);
  }
  @override
  Future<WorkBuddyObservation> observe(WorkBuddySubject s) async {
    reads++;
    await onObserve?.call();
    if (reads == failObserveAt) throw const WorkBuddyFailure('ReadFailed');
    return observations.length > 1
        ? observations.removeAt(0)
        : observations.single;
  }

  @override
  Future<Map<String, Object?>> claim(WorkBuddySubject s) async {
    expect(store.rows[s.key] != null, 'POST before durable intent');
    posts++;
    store.events.add('post');
    await beforePost?.call();
    if (loseReply) throw const WorkBuddyFailure('OutcomeUnknown');
    return receipt;
  }
}

DateTime time = DateTime.utc(2026, 11, 4, 3);
Future<void> main() async {
  var pass = 0, fail = 0;
  Future<void> check(String name, FutureOr<void> Function() body) async {
    time = DateTime.utc(2026, 11, 4, 3);
    try {
      await body();
      pass++;
      stdout.writeln('PASS $name');
    } catch (e) {
      fail++;
      stdout.writeln('FAIL $name: $e');
    }
  }

  await check('explicit qualification and authoritative error codes', () {
    expect(
      WorkBuddyProtocol.status({'code': 0, 'data': {}}) ==
          WorkBuddyState.unconfirmed,
      'missing fields',
    );
    expect(
      WorkBuddyProtocol.status(status(false)) == WorkBuddyState.available,
      'eligible',
    );
    expect(
      WorkBuddyProtocol.status(status(false, active: false)) ==
          WorkBuddyState.unavailable,
      'inactive',
    );
    expect(
      WorkBuddyProtocol.status(status(true)) == WorkBuddyState.alreadyClaimed,
      'already',
    );
    expect(
      WorkBuddyProtocol.status({'code': 10085}) ==
          WorkBuddyState.needsVerification,
      'auth',
    );
  });
  await check(
    'receipt plus status plus balance required for credited success',
    () {
      expect(
        WorkBuddyProtocol.reconcile(
              WorkBuddyState.claimed,
              WorkBuddyState.alreadyClaimed,
              10,
              30,
              20,
            ).credited ==
            20,
        'gain',
      );
      expect(
        WorkBuddyProtocol.reconcile(
              WorkBuddyState.claimed,
              WorkBuddyState.alreadyClaimed,
              10,
              10,
              20,
            ).state ==
            WorkBuddyState.unconfirmed,
        'no actual gain',
      );
      expect(
        WorkBuddyProtocol.reconcile(
              WorkBuddyState.unconfirmed,
              WorkBuddyState.alreadyClaimed,
              10,
              30,
              null,
            ).credited ==
            null,
        'unknown receipt',
      );
    },
  );
  await check(
    'one successful transaction persists before send and confirms readback',
    () async {
      final s = MemoryStore();
      final t = FakeTransport(s);
      final c = WorkBuddyClaimCore(s, t, () => time, isCurrent: (_) => true);
      final r = await c.claim(subject);
      expect(
        r.state == WorkBuddyState.claimed && r.credited == 20,
        'confirmed outcome',
      );
      expect(t.posts == 1 && t.reads == 2, 'request count');
      expect(s.events.first == 'persist', 'write ordering');
      await c.claim(subject);
      expect(t.posts == 1, 'same day replay');
    },
  );
  for (final balance in <double?>[null, double.nan, double.infinity, -1]) {
    await check(
      'unknown or invalid pre-balance never submits ($balance)',
      () async {
        final s = MemoryStore();
        final t = FakeTransport(s);
        t.observations[0] = WorkBuddyObservation(
          subject,
          status(false),
          balance,
        );
        final r = await WorkBuddyClaimCore(
          s,
          t,
          () => time,
          isCurrent: (_) => true,
        ).claim(subject);
        expect(
          t.posts == 0 && r.state == WorkBuddyState.unconfirmed,
          'invalid balance admitted',
        );
      },
    );
  }
  await check('inactive/already claimed never submits', () async {
    for (final st in [status(false, active: false), status(true)]) {
      final s = MemoryStore();
      final t = FakeTransport(s);
      t.observations[0] = WorkBuddyObservation(subject, st, 10);
      await WorkBuddyClaimCore(
        s,
        t,
        () => time,
        isCurrent: (_) => true,
      ).claim(subject);
      expect(t.posts == 0, 'ineligible sent');
    }
  });
  await check(
    'unknown send survives a new owner and never replays next day',
    () async {
      final s = MemoryStore();
      final t = FakeTransport(s)..loseReply = true;
      final r = await WorkBuddyClaimCore(
        s,
        t,
        () => time,
        isCurrent: (_) => true,
      ).claim(subject);
      expect(
        r.state == WorkBuddyState.unconfirmed && r.credited == null,
        'unknown must remain unknown',
      );
      time = time.add(const Duration(days: 1));
      await WorkBuddyClaimCore(
        s,
        t,
        () => time,
        isCurrent: (_) => true,
      ).claim(subject);
      expect(t.posts == 1, 'unknown replayed');
    },
  );
  await check('storage failure prevents dispatch', () async {
    final s = MemoryStore()..fail = true;
    final t = FakeTransport(s);
    var denied = false;
    try {
      await WorkBuddyClaimCore(
        s,
        t,
        () => time,
        isCurrent: (_) => true,
      ).claim(subject);
    } on WorkBuddyFailure catch (e) {
      denied = e.code == 'StorageUnavailable';
    }
    expect(denied && t.posts == 0, 'sent after persistence failed');
  });
  await check('concurrent owners share one CAS submit grant', () async {
    final s = MemoryStore();
    final t = FakeTransport(s);
    t.observations.clear();
    t.observations.add(WorkBuddyObservation(subject, status(false), 10));
    final results = await Future.wait([
      WorkBuddyClaimCore(
        s,
        t,
        () => time,
        isCurrent: (_) => true,
      ).claim(subject),
      WorkBuddyClaimCore(
        s,
        t,
        () => time,
        isCurrent: (_) => true,
      ).claim(subject),
    ]);
    expect(results.length == 2 && t.posts == 1, 'duplicate submit');
  });
  await check(
    'changed credential generation cannot reuse old attempt',
    () async {
      final s = MemoryStore();
      final t = FakeTransport(s)..loseReply = true;
      await WorkBuddyClaimCore(
        s,
        t,
        () => time,
        isCurrent: (_) => true,
      ).claim(subject);
      var denied = false;
      try {
        await WorkBuddyClaimCore(
          s,
          t,
          () => time,
          isCurrent: (_) => true,
        ).claim(WorkBuddySubject(subject.domain, subject.uid, 'generation-2'));
      } on WorkBuddyFailure {
        denied = true;
      }
      expect(denied && t.posts == 1, 'generation replaced pending');
    },
  );
  await check(
    'wrong authenticated observation subject prevents submit',
    () async {
      final s = MemoryStore();
      final t = FakeTransport(s);
      t.observations[0] = WorkBuddyObservation(
        WorkBuddySubject(subject.domain, 'other', 'generation-1'),
        status(false),
        10,
      );
      var denied = false;
      try {
        await WorkBuddyClaimCore(
          s,
          t,
          () => time,
          isCurrent: (_) => true,
        ).claim(subject);
      } on WorkBuddyFailure catch (e) {
        denied = e.code == 'IdentityMismatch';
      }
      expect(denied && t.posts == 0, 'wrong subject sent');
    },
  );
  await check('malformed numeric credit never reports a gain', () {
    for (final value in [double.nan, double.infinity, -1, 'NaN', '-5', null]) {
      expect(
        WorkBuddyProtocol.credit({
              'code': 0,
              'data': {'credit': value},
            }) ==
            null,
        'invalid credit accepted',
      );
    }
  });
  await check(
    'known receipt survives failed readback and reconciles without resubmit',
    () async {
      final s = MemoryStore();
      final t = FakeTransport(s)..failObserveAt = 2;
      final first = await WorkBuddyClaimCore(
        s,
        t,
        () => time,
        isCurrent: (_) => true,
      ).claim(subject);
      expect(
        first.state == WorkBuddyState.unconfirmed,
        'failed read falsely confirmed',
      );
      t.failObserveAt = null;
      final recovered = await WorkBuddyClaimCore(
        s,
        t,
        () => time,
        isCurrent: (_) => true,
      ).claim(subject);
      expect(
        recovered.state == WorkBuddyState.claimed &&
            recovered.credited == 20 &&
            t.posts == 1,
        'recovery failed/replayed',
      );
    },
  );
  await check(
    'insufficient balance readback stays unknown until corroborated',
    () async {
      final s = MemoryStore();
      final t = FakeTransport(s);
      t.observations[1] = WorkBuddyObservation(subject, status(true), 10);
      expect(
        (await WorkBuddyClaimCore(
              s,
              t,
              () => time,
              isCurrent: (_) => true,
            ).claim(subject)).state ==
            WorkBuddyState.unconfirmed,
        'uncredited success',
      );
      t.observations[0] = WorkBuddyObservation(subject, status(true), 30);
      expect(
        (await WorkBuddyClaimCore(
                  s,
                  t,
                  () => time,
                  isCurrent: (_) => true,
                ).claim(subject)).credited ==
                20 &&
            t.posts == 1,
        'no reconciliation',
      );
    },
  );
  await check(
    'midnight during eligibility observation prevents submit',
    () async {
      final s = MemoryStore();
      final t = FakeTransport(s);
      t.onObserve = () async {
        time = time.add(const Duration(days: 1));
      };
      await WorkBuddyClaimCore(
        s,
        t,
        () => time,
        isCurrent: (_) => true,
      ).claim(subject);
      expect(t.posts == 0 && s.rows.isEmpty, 'stale day admitted');
    },
  );
  await check(
    'known yesterday receipt cannot be reconciled using today status',
    () async {
      final s = MemoryStore();
      final t = FakeTransport(s)..failObserveAt = 2;
      await WorkBuddyClaimCore(
        s,
        t,
        () => time,
        isCurrent: (_) => true,
      ).claim(subject);
      time = time.add(const Duration(days: 1));
      t.failObserveAt = null;
      final r = await WorkBuddyClaimCore(
        s,
        t,
        () => time,
        isCurrent: (_) => true,
      ).claim(subject);
      expect(
        r.state == WorkBuddyState.unconfirmed && t.posts == 1,
        'cross day replay/confirmation',
      );
    },
  );
  await check(
    'settled previous day permits a separate next day operation',
    () async {
      final s = MemoryStore();
      final t = FakeTransport(s);
      await WorkBuddyClaimCore(
        s,
        t,
        () => time,
        isCurrent: (_) => true,
      ).claim(subject);
      time = time.add(const Duration(days: 1));
      t.observations.clear();
      t.observations.addAll([
        WorkBuddyObservation(subject, status(false), 30),
        WorkBuddyObservation(subject, status(true), 50),
      ]);
      final r = await WorkBuddyClaimCore(
        s,
        t,
        () => time,
        isCurrent: (_) => true,
      ).claim(subject);
      expect(r.credited == 20 && t.posts == 2, 'next day operation blocked');
    },
  );
  await check(
    'post-response storage failure retains unknown intent and never repeats',
    () async {
      final s = MemoryStore();
      final t = FakeTransport(s);
      t.beforePost = () async {
        s.fail = true;
      };
      var failed = false;
      try {
        await WorkBuddyClaimCore(
          s,
          t,
          () => time,
          isCurrent: (_) => true,
        ).claim(subject);
      } on WorkBuddyFailure {
        failed = true;
      }
      expect(
        failed &&
            t.posts == 1 &&
            s.rows[subject.key]!.receipt == WorkBuddyState.unconfirmed,
        'lost intent',
      );
      s.fail = false;
      await WorkBuddyClaimCore(
        s,
        t,
        () => time,
        isCurrent: (_) => true,
      ).claim(subject);
      expect(t.posts == 1, 'post storage error replayed');
    },
  );
  await check('claim error codes preserve non-gain outcomes', () async {
    for (final pair in {
      1001: WorkBuddyState.alreadyClaimed,
      1002: WorkBuddyState.unavailable,
      401: WorkBuddyState.needsVerification,
    }.entries) {
      final s = MemoryStore();
      final t = FakeTransport(s)..receipt = {'code': pair.key};
      final r = await WorkBuddyClaimCore(
        s,
        t,
        () => time,
        isCurrent: (_) => true,
      ).claim(subject);
      expect(
        r.state == pair.value && r.credited == null && t.posts == 1,
        'error state changed',
      );
    }
  });
  await check(
    'pending authorization failure remains visible without clearing intent',
    () async {
      final s = MemoryStore();
      final t = FakeTransport(s)..loseReply = true;
      t.observations[1] = WorkBuddyObservation(subject, {'code': 401}, null);
      final r = await WorkBuddyClaimCore(
        s,
        t,
        () => time,
        isCurrent: (_) => true,
      ).claim(subject);
      expect(
        r.state == WorkBuddyState.needsVerification &&
            s.rows[subject.key]!.settled == WorkBuddyState.unconfirmed,
        'pending auth status lost',
      );
    },
  );
  await check('settled earlier generation does not permanently block reauthorized account', () async {
    final s = MemoryStore();
    final t = FakeTransport(s);
    await WorkBuddyClaimCore(
      s,
      t,
      () => time,
      isCurrent: (_) => true,
    ).claim(subject);
    time = time.add(const Duration(days: 1));
    final next = WorkBuddySubject(subject.domain, subject.uid, 'generation-2');
    t.observations.clear();
    t.observations.addAll([
      WorkBuddyObservation(next, status(false), 30),
      WorkBuddyObservation(next, status(true), 50),
    ]);
    final r = await WorkBuddyClaimCore(
      s,
      t,
      () => time,
      isCurrent: (_) => true,
    ).claim(next);
    expect(
      r.credited == 20 && t.posts == 2,
      'reauthorized account permanently blocked',
    );
  });
  await check(
    'settlement crossing midnight does not report yesterday gain as today',
    () async {
      final s = MemoryStore();
      final t = FakeTransport(s);
      s.onCas = (attempt) {
        if (attempt.settled == WorkBuddyState.claimed)
          time = time.add(const Duration(days: 1));
      };
      final r = await WorkBuddyClaimCore(
        s,
        t,
        () => time,
        isCurrent: (_) => true,
      ).claim(subject);
      expect(
        r.state == WorkBuddyState.unconfirmed && r.credited == null,
        'late yesterday gain exposed',
      );
    },
  );
  await check(
    'retired owner before begin performs no reads or sends',
    () async {
      final s = MemoryStore();
      final t = FakeTransport(s);
      var denied = false;
      try {
        await WorkBuddyClaimCore(
          s,
          t,
          () => time,
          isCurrent: (_) => false,
        ).claim(subject);
      } on WorkBuddyFailure catch (e) {
        denied = e.code == 'ExpiredAuthorization';
      }
      expect(
        denied && t.posts == 0 && t.reads == 0 && s.rows.isEmpty,
        'retired owner progressed',
      );
    },
  );
  await check(
    'owner retired during intent persistence cannot dispatch',
    () async {
      final s = MemoryStore();
      final t = FakeTransport(s);
      var live = true;
      var denied = false;
      s.onCas = (_) {
        live = false;
      };
      try {
        await WorkBuddyClaimCore(
          s,
          t,
          () => time,
          isCurrent: (_) => live,
        ).claim(subject);
      } on WorkBuddyFailure catch (e) {
        denied = e.code == 'ExpiredAuthorization';
      }
      expect(
        denied &&
            t.posts == 0 &&
            s.rows[subject.key]!.settled == WorkBuddyState.unconfirmed,
        'post crossed cancellation',
      );
    },
  );
  await check(
    'owner retired after send cannot report or persist a success',
    () async {
      final s = MemoryStore();
      final t = FakeTransport(s);
      var live = true;
      var denied = false;
      t.beforePost = () async {
        live = false;
      };
      try {
        await WorkBuddyClaimCore(
          s,
          t,
          () => time,
          isCurrent: (_) => live,
        ).claim(subject);
      } on WorkBuddyFailure catch (e) {
        denied = e.code == 'ExpiredAuthorization';
      }
      expect(
        denied &&
            t.posts == 1 &&
            s.rows[subject.key]!.receipt == WorkBuddyState.unconfirmed,
        'late receipt revived owner',
      );
    },
  );
  await check(
    'cached settled read crossing midnight is not labeled today',
    () async {
      final s = MemoryStore();
      final t = FakeTransport(s);
      await WorkBuddyClaimCore(
        s,
        t,
        () => time,
        isCurrent: (_) => true,
      ).claim(subject);
      s.onRead = () {
        time = time.add(const Duration(days: 1));
      };
      final r = await WorkBuddyClaimCore(
        s,
        t,
        () => time,
        isCurrent: (_) => true,
      ).claim(subject);
      expect(
        r.state == WorkBuddyState.unconfirmed && t.posts == 1,
        'yesterday cached result exposed',
      );
    },
  );
  stdout.writeln('$pass passed, $fail failed');
  if (fail != 0) exitCode = 1;
}
