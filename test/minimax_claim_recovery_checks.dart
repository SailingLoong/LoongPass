import 'dart:io';

import '../lib/minimax_accounts.dart';
import '../lib/minimax_http.dart';
import '../lib/minimax_oauth.dart';
import 'memory_account_store.dart';
import 'minimax_accounts_checks.dart' as f;

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Map<String, dynamic> panel(int today, {int status = 2}) => {
  'days': [
    for (var day = 1; day <= 7; day++)
      {
        'day_no': day,
        'points': 20,
        'status': day == today ? status : 1,
        'is_today': day == today,
      },
  ],
};

Future<void> main() async {
  var failed = 0;
  Future<void> run(String name, Future<void> Function() test) async {
    try {
      await test();
      print('PASS $name');
    } catch (e) {
      failed++;
      print('FAIL $name: $e');
    }
  }

  Future<(MiniMaxAccounts, MiniMaxAccount)> seed(
    MemoryAccountStore store,
    f.FakeHttp http,
    int Function() now,
  ) async {
    final owner = MiniMaxAccounts(
      store: MiniMaxAccountStore(store),
      http: http,
      nowMs: now,
    );
    final credential = MiniMaxCredential.authorization(
      MiniMaxOAuthToken(
        'synthetic-access',
        now() + 600000,
        'synthetic-refresh',
      ),
      'cn',
    );
    final saved = await owner.save(
      await owner.verifySource(() async => credential, confirmed: true),
      confirmed: true,
      automatic: true,
    );
    store.data['accounts'][saved.id]['operation'] = {
      'id': 'legacy-unknown',
      'day': '2026-11-01',
      'state': 'unknown',
      'points': null,
      'claimId': null,
    };
    store.data['accounts'][saved.id]['previousSuccessfulOperation'] = {
      'id': 'earlier-confirmed',
      'day': '2026-10-31',
      'state': 'claimed',
      'points': 10,
      'confirmedAtMs': 90000,
    };
    store.data['accounts'][saved.id]['status'] = 'unknown';
    return (owner, saved);
  }

  await run(
    'legacy MiniMax uncertainty anchors a server day read-only and survives local midnight/restart',
    () async {
      var now = 100000;
      final store = MemoryAccountStore('minimax-legacy-day-anchor'),
          http = f.FakeHttp()..status = f.response(panel(1));
      final (owner, saved) = await seed(store, http, () => now);
      try {
        await owner.claim(saved.id);
        final op = store.data['accounts'][saved.id]['operation'];
        check(
          http.calls.where((v) => v == MiniMaxEndpoint.status).length == 1 &&
              !http.calls.contains(MiniMaxEndpoint.claim),
          'unknown result prevented read-only status or was replayed',
        );
        check(
          op['state'] == 'unknown' &&
              op['serverDay'] == null &&
              op['reconciliationDay'] == 1,
          'first observation fabricated a receipt or original attempt day',
        );
      } finally {
        owner.dispose();
      }
      now += const Duration(days: 1).inMilliseconds;
      final restored = MiniMaxAccounts(
        store: MiniMaxAccountStore(store),
        http: http,
        nowMs: () => now,
      );
      try {
        await restored.claim(saved.id);
        final result = (await restored.list()).single;
        check(
          http.calls.where((v) => v == MiniMaxEndpoint.status).length == 2 &&
              !http.calls.contains(MiniMaxEndpoint.claim),
          'local midnight or restart replayed the same uncertain vendor day',
        );
        check(
          result.latestClaim?.amount == 10,
          'uncertainty replaced the earlier confirmed10-point receipt',
        );
        await restored.setAutomatic(saved.id, false);
        final before = http.calls
            .where((v) => v == MiniMaxEndpoint.status)
            .length;
        await restored.automaticTick();
        check(
          http.calls.where((v) => v == MiniMaxEndpoint.status).length ==
                  before &&
              !http.calls.contains(MiniMaxEndpoint.claim),
          'automatic opt-out was ignored',
        );
      } finally {
        restored.dispose();
      }
    },
  );

  await run(
    'observed MiniMax server-day advancement permits one independent claim and preserves unknown history',
    () async {
      final store = MemoryAccountStore('minimax-advanced-server-day'),
          http = f.FakeHttp()..status = f.response(panel(1));
      final (owner, saved) = await seed(store, http, () => 100000);
      try {
        await owner.claim(saved.id);
        http.status = f.response(panel(2));
        http.receipt = f.response({
          'claim_result': 1,
          'points': 20,
          'day_no': 2,
        });
        final result = await owner.claim(saved.id);
        check(
          result.status == 'claimed' &&
              result.points == 20 &&
              result.latestClaim?.amount == 20,
          'new vendor day did not retain the confirmed20-point claim',
        );
        final row = store.data['accounts'][saved.id];
        final history = row['unresolvedOperations'] as List;
        check(
          history.length == 1 &&
              history.single['id'] == 'legacy-unknown' &&
              history.single['state'] == 'unknown' &&
              history.single['points'] == null,
          'the uncertain receipt was lost or converted to success',
        );
        check(
          row['operation']['serverDay'] == 2,
          'claim did not record its observed vendor day',
        );
        await owner.claim(saved.id);
        check(
          http.calls.where((v) => v == MiniMaxEndpoint.claim).length == 1 &&
              (store.data['accounts'][saved.id]['unresolvedOperations'] as List)
                      .length ==
                  1,
          'same server day replayed or archived uncertainty twice',
        );
      } finally {
        owner.dispose();
      }
      final restored = MiniMaxAccounts(
        store: MiniMaxAccountStore(store),
        http: http,
        nowMs: () => 100000,
      );
      try {
        await restored.claim(saved.id);
        http.status = f.response(panel(3));
        http.loseClaim = true;
        final result = await restored.claim(saved.id);
        check(
          result.status == 'unknown' && result.latestClaim?.amount == 20,
          'a later uncertain day erased successful-claim history',
        );
        await restored.claim(saved.id);
        check(
          http.calls.where((v) => v == MiniMaxEndpoint.claim).length == 2,
          'a newly uncertain day was replayed',
        );
        check(
          (store.data['accounts'][saved.id]['unresolvedOperations'] as List)
                  .length ==
              1,
          'restart duplicated archived uncertainty',
        );
      } finally {
        restored.dispose();
      }
    },
  );

  await run(
    'a MiniMax uncertain POST spanning a server-day change anchors after the outcome before any new claim',
    () async {
      final store = MemoryAccountStore('minimax-uncertain-day-boundary'),
          http = f.FakeHttp()..status = f.response(panel(7));
      final (owner, saved) = await seed(store, http, () => 100000);
      store.data['accounts'][saved.id]['operation'] = null;
      http.loseClaim = true;
      try {
        await owner.claim(saved.id);
        http.status = f.response(panel(1));
        await owner.claim(saved.id);
        check(
          http.calls.where((v) => v == MiniMaxEndpoint.claim).length == 1 &&
              store.data['accounts'][saved
                      .id]['operation']['reconciliationDay'] ==
                  1,
          'preflight day change replayed an uncertain boundary-spanning POST',
        );
        http.loseClaim = false;
        http.status = f.response(panel(2));
        http.receipt = f.response({
          'claim_result': 1,
          'points': 20,
          'day_no': 2,
        });
        final result = await owner.claim(saved.id);
        check(
          result.status == 'claimed' &&
              result.points == 20 &&
              http.calls.where((v) => v == MiniMaxEndpoint.claim).length == 2,
          'a subsequent observed server day did not admit one independent claim',
        );
      } finally {
        owner.dispose();
      }
    },
  );

  await run(
    'a completed MiniMax server slot can recur next cycle while its confirmed current date stays duplicate-safe',
    () async {
      final now = DateTime.utc(2026, 11, 8, 12).millisecondsSinceEpoch;
      final prior = DateTime.utc(2026, 11, 1, 12).millisecondsSinceEpoch;
      final store = MemoryAccountStore('minimax-completed-recurring-slot'),
          http = f.FakeHttp()..status = f.response(panel(1));
      final (owner, saved) = await seed(store, http, () => now);
      store.data['accounts'][saved.id]['operation'] = {
        'id': 'last-cycle-confirmed',
        'day': '2026-11-01',
        'state': 'claimed',
        'serverDay': 1,
        'points': 10,
        'confirmedAtMs': prior,
      };
      http.receipt = f.response({'claim_result': 1, 'points': 20, 'day_no': 1});
      try {
        final result = await owner.claim(saved.id);
        check(
          result.status == 'claimed' &&
              result.points == 20 &&
              http.calls.where((v) => v == MiniMaxEndpoint.claim).length == 1,
          'a repeating server slot suppressed the next cycle claim',
        );
        await owner.claim(saved.id);
        check(
          http.calls.where((v) => v == MiniMaxEndpoint.claim).length == 1,
          'the current confirmed cycle was claimed twice',
        );
      } finally {
        owner.dispose();
      }
    },
  );

  await run(
    'MiniMax already-claimed status is an observation and never invents the old receipt',
    () async {
      final store = MemoryAccountStore('minimax-observed-claimed-day'),
          http = f.FakeHttp()..status = f.response(panel(4, status: 3));
      final (owner, saved) = await seed(store, http, () => 100000);
      try {
        final result = await owner.claim(saved.id);
        final op = store.data['accounts'][saved.id]['operation'];
        check(
          result.status == 'alreadyClaimed' &&
              result.latestClaim?.amount == 10 &&
              op['state'] == 'unknown' &&
              op['confirmedAtMs'] == null &&
              !http.calls.contains(MiniMaxEndpoint.claim),
          'read-only current status was attributed to the unknown historical POST',
        );
      } finally {
        owner.dispose();
      }
    },
  );

  await run(
    'MiniMax day-anchor persistence failure and changed account stop before any POST',
    () async {
      final store = MemoryAccountStore('minimax-day-anchor-cas'),
          http = f.FakeHttp()..status = f.response(panel(1));
      final (owner, saved) = await seed(store, http, () => 100000);
      try {
        store.beforeWrite = () async =>
            throw StateError('synthetic disk failure');
        var rejected = false;
        try {
          await owner.claim(saved.id);
        } on MiniMaxAccountError catch (e) {
          rejected = e.code == 'StorageUnavailable';
        }
        check(
          rejected &&
              store.data['accounts'][saved
                      .id]['operation']['reconciliationDay'] ==
                  null &&
              !http.calls.contains(MiniMaxEndpoint.claim),
          'unpublished anchor was accepted',
        );
        store.beforeWrite = null;
        http.pause = (endpoint) async {
          if (endpoint == MiniMaxEndpoint.status) {
            store.data['accounts'][saved.id]['generation']++;
            store.revision++;
          }
        };
        rejected = false;
        try {
          await owner.claim(saved.id);
        } on MiniMaxAccountError catch (e) {
          rejected = e.code == 'SourceChanged';
        }
        check(
          rejected && !http.calls.contains(MiniMaxEndpoint.claim),
          'stale status mutated the replaced account',
        );
      } finally {
        owner.dispose();
      }
    },
  );
  exitCode = failed == 0 ? 0 : 1;
}
