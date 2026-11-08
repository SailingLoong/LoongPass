import 'dart:async';
import 'dart:io';

import '../lib/minimax_accounts.dart';
import '../lib/minimax_oauth.dart';
import '../lib/minimax_http.dart';
import 'memory_account_store.dart';
import 'minimax_accounts_checks.dart' as f;

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

class AccountHttp extends f.FakeHttp {
  bool refuseCredits = false;
  @override
  Future<MiniMaxReply> credits({
    required String accessToken,
    required String region,
    required String userId,
    required int pageNumber,
    bool Function()? isCurrent,
  }) async {
    if (refuseCredits) return const MiniMaxReply(401, null);
    return super.credits(
      accessToken: accessToken,
      region: region,
      userId: userId,
      pageNumber: pageNumber,
      isCurrent: isCurrent,
    );
  }
}

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

  Future<MiniMaxAccount> authorize(
    MiniMaxAccounts owner, {
    String token = 'synthetic-access',
  }) async {
    final credential = MiniMaxCredential.authorization(
      MiniMaxOAuthToken(token, 3700000, 'synthetic-refresh'),
      'cn',
    );
    return owner.save(
      await owner.verifySource(() async => credential, confirmed: true),
      confirmed: true,
    );
  }

  MiniMaxAccounts open(MemoryAccountStore store, f.FakeHttp http) =>
      MiniMaxAccounts(
        store: MiniMaxAccountStore(store),
        http: http,
        nowMs: () => 100000,
      );

  Future<void> report(
    MiniMaxAccounts owner,
    String id,
    String registration,
    String token,
  ) => Future<void>.sync(
    () => owner.rejectInferenceAuthorization(id, registration, token),
  );

  Future<String> read(MiniMaxAccounts owner, String id) =>
      owner.withInferenceAuthorization(id, (
        region,
        token,
        current,
        registration,
      ) async {
        check(current(), 'invalid lease');
        return token;
      });

  await run(
    'MiniMax exact-token rejection persists across restart and clears on rotation',
    () async {
      final store = MemoryAccountStore('minimax-persisted-401'),
          http = f.FakeHttp();
      final owner = open(store, http);
      final saved = await authorize(owner);
      try {
        await report(
          owner,
          saved.id,
          saved.registrationId!,
          'synthetic-access',
        );
      } finally {
        owner.dispose();
      }
      final restored = open(store, http);
      try {
        check(
          await read(restored, saved.id) == 'synthetic-new',
          'restart reused a rejected access token',
        );
        check(
          http.refreshCalls == 1 &&
              store.data['accounts'][saved.id]['accessRejected'] == false,
          'rejection was not cleared with persisted rotation',
        );
      } finally {
        restored.dispose();
      }
    },
  );

  await run(
    'stale MiniMax token or registration rejection never changes a newer login',
    () async {
      final store = MemoryAccountStore('minimax-stale-401'),
          http = f.FakeHttp();
      final owner = open(store, http);
      try {
        final original = await authorize(owner);
        await authorize(owner, token: 'synthetic-new');
        final before = store.revision;
        await report(
          owner,
          original.id,
          original.registrationId!,
          'synthetic-access',
        );
        await report(owner, original.id, 'other-registration', 'synthetic-new');
        check(
          await read(owner, original.id) == 'synthetic-new' &&
              http.refreshCalls == 0,
          'stale refusal rejected a newer login',
        );
        check(
          store.revision == before,
          'stale refusal wrote the current account',
        );
      } finally {
        owner.dispose();
      }
    },
  );

  await run(
    'failed MiniMax rejection persistence blocks reuse until publication succeeds',
    () async {
      final store = MemoryAccountStore('minimax-rejection-save-failure'),
          http = f.FakeHttp();
      final owner = open(store, http);
      try {
        final saved = await authorize(owner);
        store.beforeWrite = () async =>
            throw StateError('synthetic disk unavailable');
        var failures = 0;
        for (final operation in [
          () => report(
            owner,
            saved.id,
            saved.registrationId!,
            'synthetic-access',
          ),
          () => read(owner, saved.id),
        ]) {
          try {
            await operation();
          } on MiniMaxAccountError catch (e) {
            if (e.code == 'StorageUnavailable') failures++;
          }
        }
        check(
          failures == 2 && http.refreshCalls == 0,
          'unpublished rejection allowed authorization or spent refresh',
        );
        store.beforeWrite = null;
        check(
          await read(owner, saved.id) == 'synthetic-new' &&
              http.refreshCalls == 1,
          'saved rejection did not recover through owner rotation',
        );
      } finally {
        owner.dispose();
      }
    },
  );

  await run(
    'lost MiniMax rejection-save acknowledgement still protects the restarted owner',
    () async {
      final store = MemoryAccountStore('minimax-rejection-lost-ack'),
          http = f.FakeHttp();
      final owner = open(store, http);
      final saved = await authorize(owner);
      store.afterWrite = () async =>
          throw StateError('synthetic lost acknowledgement');
      try {
        try {
          await report(
            owner,
            saved.id,
            saved.registrationId!,
            'synthetic-access',
          );
        } on MiniMaxAccountError {}
      } finally {
        owner.dispose();
      }
      store.afterWrite = null;
      final restored = open(store, http);
      try {
        check(
          await read(restored, saved.id) == 'synthetic-new' &&
              http.refreshCalls == 1,
          'committed rejection was lost with its acknowledgement',
        );
      } finally {
        restored.dispose();
      }
    },
  );

  await run(
    'MiniMax account403 does not reject an otherwise usable authorization',
    () async {
      final store = MemoryAccountStore('minimax-account-forbidden'),
          http = f.FakeHttp();
      final owner = open(store, http);
      try {
        final saved = await authorize(owner);
        http.status = const MiniMaxReply(403, null);
        try {
          await owner.claim(saved.id);
        } on MiniMaxAccountError {}
        check(
          await read(owner, saved.id) == 'synthetic-access' &&
              http.refreshCalls == 0 &&
              store.data['accounts'][saved.id]['accessRejected'] != true,
          'an unrelated403 invalidated or renewed the account grant',
        );
      } finally {
        owner.dispose();
      }
    },
  );

  for (final endpoint in ['profile', 'status', 'credits']) {
    await run(
      'MiniMax saved-account $endpoint HTTP401 persists rejection for the next independent authorization',
      () async {
        final store = MemoryAccountStore('minimax-account-refusal-$endpoint'),
            http = AccountHttp();
        final seed = open(store, http);
        final saved = await authorize(seed);
        seed.dispose();
        if (endpoint == 'profile') http.profile = const MiniMaxReply(401, null);
        if (endpoint == 'status') http.status = const MiniMaxReply(401, null);
        if (endpoint == 'credits') http.refuseCredits = true;
        final owner = open(store, http);
        try {
          try {
            if (endpoint == 'credits')
              await owner.refreshCredits(saved.id);
            else
              await owner.claim(saved.id);
          } on MiniMaxAccountError {}
          check(
            store.data['accounts'][saved.id]['accessRejected'] == true &&
                http.refreshCalls == 0 &&
                !http.calls.contains(MiniMaxEndpoint.claim),
            'definite account401 was lost or immediately retried',
          );
        } finally {
          owner.dispose();
        }
        http.profile = f.FakeHttp().profile;
        http.status = f.FakeHttp().status;
        http.refuseCredits = false;
        final restored = open(store, http);
        try {
          check(
            await read(restored, saved.id) == 'synthetic-new' &&
                http.refreshCalls == 1,
            'later authorization reused a native-gateway rejected token',
          );
        } finally {
          restored.dispose();
        }
      },
    );
  }

  await run(
    'a MiniMax claim401 renews future authorization without replaying its uncertain reward POST',
    () async {
      final store = MemoryAccountStore('minimax-claim401-no-replay'),
          http = f.FakeHttp()..receipt = const MiniMaxReply(401, null);
      final owner = open(store, http);
      try {
        final saved = await authorize(owner);
        check(
          (await owner.claim(saved.id)).status == 'unknown' &&
              store.data['accounts'][saved.id]['accessRejected'] == true &&
              http.refreshCalls == 0,
          'claim401 was replayed or token rejection was lost',
        );
        check(
          await read(owner, saved.id) == 'synthetic-new' &&
              http.refreshCalls == 1,
          'future inference authorization did not renew the rejected grant',
        );
        await owner.claim(saved.id);
        check(
          http.calls.where((v) => v == MiniMaxEndpoint.claim).length == 1 &&
              store.data['accounts'][saved.id]['operation']['state'] ==
                  'unknown',
          'renewal replayed or rewrote the uncertain reward receipt',
        );
      } finally {
        owner.dispose();
      }
    },
  );

  await run(
    'MiniMax rejection settles after another lease without deadlock or stale mutation',
    () async {
      final store = MemoryAccountStore('minimax-rejection-serialization'),
          http = f.FakeHttp();
      final owner = open(store, http);
      final saved = await authorize(owner);
      final entered = Completer<void>(), release = Completer<void>();
      final lease = owner.withInferenceAuthorization(saved.id, (
        region,
        token,
        current,
        registration,
      ) async {
        entered.complete();
        await release.future;
      });
      try {
        await entered.future;
        var settled = false;
        final rejection = report(
          owner,
          saved.id,
          saved.registrationId!,
          'synthetic-access',
        ).then((_) => settled = true);
        await Future<void>.delayed(Duration.zero);
        check(!settled, 'rejection bypassed the active owner lease');
        release.complete();
        await lease;
        await rejection.timeout(const Duration(seconds: 1));
        check(
          await read(owner, saved.id) == 'synthetic-new',
          'queued rejection did not invalidate the exact lease',
        );
      } finally {
        if (!release.isCompleted) release.complete();
        await lease;
        owner.dispose();
      }
    },
  );
  exitCode = failed == 0 ? 0 : 1;
}
