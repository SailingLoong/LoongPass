import 'dart:io';

import '../lib/minimax_accounts.dart';
import '../lib/minimax_http.dart';
import '../lib/minimax_oauth.dart';
import 'memory_account_store.dart';
import 'minimax_accounts_checks.dart' as f;

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

class OAuthReply extends MiniMaxHttp {
  Map<String, dynamic> token = {
    'access_token': 'synthetic-opaque-token',
    'refresh_token': 'synthetic-new-refresh',
    'token_type': 'Bearer',
    'expires_in': 3600,
  };

  @override
  Future<MiniMaxReply> oauth(
    String path,
    String region,
    Map<String, String> body, {
    bool Function()? isCurrent,
  }) async {
    if (path.endsWith('/code')) {
      check(body['scope'] == 'agent.default', 'wrong requested grant');
      return const MiniMaxReply(200, {
        'user_code': 'synthetic-user-code',
        'device_code': 'synthetic-device-code',
        'expires_in': 300,
        'verification_uri': 'https://account.minimax.cn/login',
      });
    }
    return MiniMaxReply(200, token);
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

  await run(
    'omitted response scope retains the requested MiniMax grant',
    () async {
      final http = OAuthReply();
      final flow = MiniMaxOAuth(region: 'cn', http: http, nowMs: () => 100000);
      try {
        await flow.begin();
        final token = await flow.poll();
        check(
          token?.accessToken == 'synthetic-opaque-token' &&
              token?.refreshToken == 'synthetic-new-refresh' &&
              token?.expiresAtMs == 3700000,
          'omitted scope lost token or absolute expiry',
        );
      } finally {
        flow.cancel();
      }
    },
  );

  await run(
    'an explicit incompatible or malformed MiniMax scope is rejected',
    () async {
      for (final scope in ['other.grant', '', null, 7]) {
        final http = OAuthReply()..token['scope'] = scope;
        var rejected = false;
        try {
          await MiniMaxOAuth.refresh(
            http: http,
            region: 'cn',
            refreshToken: 'synthetic-old-refresh',
            nowMs: () => 100000,
          );
        } on MiniMaxOAuthFailure catch (e) {
          rejected = e.code == 'invalid_token';
        }
        check(rejected, 'explicit incompatible scope was accepted');
      }
    },
  );

  Future<(MiniMaxAccounts, MiniMaxAccount)> saved(
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
    final account = await owner.save(
      await owner.verifySource(() async => credential, confirmed: true),
      confirmed: true,
      automatic: true,
    );
    return (owner, account);
  }

  await run(
    'unscoped rotation is saved before profile failure and reused after restart',
    () async {
      var now = 100000;
      final store = MemoryAccountStore('minimax-unscoped-rotation');
      final http = f.FakeHttp()
        ..refreshed = const MiniMaxReply(200, {
          'access_token': 'synthetic-new',
          'refresh_token': 'synthetic-rotated',
          'token_type': 'Bearer',
          'expires_in': 3600,
        });
      final (owner, account) = await saved(store, http, () => now);
      try {
        now += 600001;
        http.profile = const MiniMaxReply(503, null);
        try {
          await owner.claim(account.id);
        } on MiniMaxAccountError {}
        final row = (store.data['accounts'] as Map).values.single;
        check(
          row['accessToken'] == 'synthetic-new' &&
              row['refreshToken'] == 'synthetic-rotated' &&
              row['expiresAtMs'] == 4300001,
          'successful rotation was lost before profile verification',
        );
      } finally {
        owner.dispose();
      }
      http.profile = f.FakeHttp().profile;
      final restored = MiniMaxAccounts(
        store: MiniMaxAccountStore(store),
        http: http,
        nowMs: () => now,
      );
      try {
        await restored.withInferenceAuthorization(account.id, (
          region,
          token,
          current,
          registration,
        ) async {
          check(token == 'synthetic-new' && current(), 'stale restored token');
        });
        check(http.refreshCalls == 1, 'single-use refresh token was replayed');
      } finally {
        restored.dispose();
      }
    },
  );

  await run(
    'minimal MiniMax panel and confirmed claim retain exact points without invented metadata',
    () async {
      final store = MemoryAccountStore('minimax-minimal-claim');
      final http = f.FakeHttp()
        ..status = f.response({'days': f.panel()['days']})
        ..receipt = f.response({'claim_result': 1, 'points': 20, 'day_no': 7});
      final (owner, account) = await saved(store, http, () => 100000);
      try {
        final result = await owner.claim(account.id);
        check(
          result.status == 'claimed' &&
              result.points == 20 &&
              result.latestClaim?.amount == 20 &&
              result.rewardExpiresAtMs == null,
          'confirmed 20-point claim was lost or expiry invented',
        );
        final operation =
            store.data['accounts'][account.id]['operation'] as Map;
        check(
          operation['claimId'] == null,
          'missing server claim id was invented',
        );
        await owner.claim(account.id);
        check(
          http.calls.where((v) => v == MiniMaxEndpoint.claim).length == 1,
          'confirmed claim was posted twice',
        );
      } finally {
        owner.dispose();
      }
    },
  );

  await run(
    'MiniMax result two and omitted optional amount remain already claimed and unknown',
    () async {
      final http = f.FakeHttp()..receipt = f.response({'claim_result': 2});
      final (owner, account) = await saved(
        MemoryAccountStore('minimax-done-without-metadata'),
        http,
        () => 100000,
      );
      try {
        final result = await owner.claim(account.id);
        check(
          result.status == 'alreadyClaimed' &&
              result.points == null &&
              result.rewardExpiresAtMs == null,
          'already-claimed outcome or unknown amount was fabricated',
        );
        await owner.claim(account.id);
        check(
          http.calls.where((v) => v == MiniMaxEndpoint.claim).length == 1,
          'already-claimed response was posted twice',
        );
      } finally {
        owner.dispose();
      }
    },
  );

  await run(
    'malformed optional MiniMax response values stay unknown without replay',
    () async {
      for (final invalid in <Map<String, dynamic>>[
        {'points': -1},
        {'points': '20'},
        {'claim_id': ''},
        {'day_no': 8},
        {'expire_at_ms': -1},
        {'panel': 'not-a-panel'},
      ]) {
        final http = f.FakeHttp()
          ..receipt = f.response({'claim_result': 1, 'points': 20, ...invalid});
        final (owner, account) = await saved(
          MemoryAccountStore('minimax-invalid-${invalid.keys.single}'),
          http,
          () => 100000,
        );
        try {
          check(
            (await owner.claim(account.id)).status == 'unknown',
            'malformed receipt accepted',
          );
          await owner.claim(account.id);
          check(
            http.calls.where((v) => v == MiniMaxEndpoint.claim).length == 1,
            'uncertain malformed receipt was retried',
          );
        } finally {
          owner.dispose();
        }
      }
    },
  );
  exitCode = failed == 0 ? 0 : 1;
}
