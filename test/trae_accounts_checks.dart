import 'dart:io';
import '../lib/trae_accounts.dart';
import '../lib/trae_http.dart';
import '../lib/trae_credits.dart';
import 'memory_account_store.dart';

const instant = 1793894400000;
void expect(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> rejected(Future<void> Function() run, String code) async {
  try {
    await run();
  } on TraeFailure catch (e) {
    expect(e.code == code, 'wrong error ${e.code}');
    return;
  }
  throw StateError('accepted');
}

Map<String, dynamic> context([String uid = 'a']) => {
  'account': {
    'uid': uid,
    'token': 'synthetic-$uid',
    'expiresAt': instant + 86400000,
    'owner': 'officialClient',
  },
  'device': {
    'DeviceID': 'synthetic-device',
    'MachineID': 'synthetic-machine',
    'ClientVersion': '3.4.11',
    'DevicePublicKey': 'synthetic-public',
    'PlatformCode': 'IDE_PC',
    'DeviceType': 'PC',
  },
  'privateKeyPEM': 'synthetic-private',
};
Map<String, dynamic> package(String id, num limit, int expiry, {num? used}) => {
  'entitlement_base_info': {
    'entitlement_id': id,
    'quota': {'credits_limit': limit},
    'end_time': expiry,
  },
  'usage': {if (used != null) 'credits_amount': used},
};

class FakeTrae implements TraeTransport {
  final signed = <String>{};
  final balances = <String, num>{};
  int claims = 0, refreshes = 0;
  bool loseReceipt = false, identityMismatch = false, failProfile = false;
  bool enabled = true;
  @override
  Future<TraeReply> post(
    String path,
    Map<String, dynamic> body, {
    String? token,
    Map<String, dynamic>? device,
    bool Function()? isCurrent,
  }) async {
    if (isCurrent?.call() == false) throw const TraeFailure('cancelled');
    final uid = token?.endsWith('-b') == true ? 'b' : 'a';
    if (path == TraeHttp.profile) {
      if (failProfile) throw const TraeFailure('network_unavailable');
      return TraeReply(200, {
        'Result': {
          'UserID': identityMismatch ? 'other' : uid,
          'ScreenName': 'Account $uid',
        },
      });
    }
    if (path == TraeHttp.exchange) {
      refreshes++;
      return TraeReply(200, {
        'Result': {
          'Token': 'synthetic-rotated',
          'RefreshToken': 'synthetic-refresh-next',
          'TokenExpireAt': instant + 86400000,
          'RefreshExpireAt': instant + 864000000,
        },
      });
    }
    if (path == TraeHttp.status)
      return TraeReply(200, {
        'code': 0,
        'enable': enabled,
        'checked_in': signed.contains(uid),
        'did_checked_in': false,
        'credits': 100,
      }, instant);
    if (path == TraeHttp.credits)
      return TraeReply(200, {
        'user_entitlement_pack_list': [
          package(
            'batch-$uid',
            balances[uid] ?? 4700,
            instant ~/ 1000 + 2592000,
          ),
        ],
      }, instant);
    if (path == TraeHttp.claim) {
      claims++;
      signed.add(uid);
      balances[uid] = (balances[uid] ?? 4700) + 100;
      if (loseReceipt) throw const TraeFailure('network_unavailable');
      return TraeReply(200, {'code': 0}, instant);
    }
    throw StateError('Unexpected endpoint');
  }
}

Future<void> main() async {
  final expiring = normalizeTraeCredits({
    'user_entitlement_pack_list': [
      {
        'entitlement_base_info': {
          'entitlement_id': 'vendor-expire-alias',
          'quota': {'credits_limit': 300},
          'expire_time': 1793900000,
        },
        'usage': {'credits_amount': 75},
      },
    ],
  }, DateTime.fromMillisecondsSinceEpoch(instant, isUtc: true));
  expect(
    expiring.totalRemaining == 225 &&
        expiring.withoutExpiry == 0 &&
        expiring.expiring.single.remaining == 225 &&
        expiring.expiring.single.expiresAt.millisecondsSinceEpoch ==
            1793900000000,
    'TRAE vendor expiry alias or exact remaining credit count was lost',
  );
  var passed = 0, failed = 0;
  Future<void> check(String name, Future<void> Function() run) async {
    try {
      await run();
      passed++;
      print('PASS $name');
    } catch (e) {
      failed++;
      print('FAIL $name: $e');
    }
  }

  TraeAccounts owner(MemoryAccountStore store, FakeTrae http) => TraeAccounts(
    store: store,
    http: http,
    proof: (key, token) async => {'Signature': 'synthetic-proof'},
    now: () => instant,
  );
  await check(
    'disabled or unavailable rewards do not suppress credits',
    () async {
      final store = MemoryAccountStore('credit-read'), http = FakeTrae();
      final first = owner(store, http);
      await first.importCurrent(context());
      first.dispose();
      final restored = owner(store, http);
      try {
        await restored.setAutomatic('a', false);
        await restored.automaticTick();
        expect(
          restored.credits('a')?.totalRemaining == 4700,
          'disabled reward policy suppressed balance',
        );
        await restored.setAutomatic('a', true);
        http.enabled = false;
        http.balances['a'] = 4600;
        await restored.automaticTick();
        expect(
          restored.credits('a')?.totalRemaining == 4600 && http.claims == 0,
          'unavailable reward suppressed current balance',
        );
      } finally {
        restored.dispose();
      }
    },
  );
  await check(
    'current authorization verifies, saves privately, restores, auto claims once',
    () async {
      final store = MemoryAccountStore('trae'),
          http = FakeTrae(),
          first = owner(MemoryAccountStore('unused'), FakeTrae());
      first.dispose();
      final app = owner(store, http);
      await app.importCurrent(context());
      app.dispose();
      final restored = owner(store, http);
      await restored.automaticTick();
      final a = (await restored.accounts()).single;
      expect(
        a.uid == 'a' && a.outcome == 'claimed' && a.credited == 100,
        'full synthetic flow',
      );
      expect(
        restored.credits('a')?.totalRemaining == 4800,
        'credit reconciliation',
      );
      restored.dispose();
      final again = owner(store, http);
      await again.automaticTick();
      expect(
        http.claims == 1 && http.refreshes == 0,
        'duplicate or competing official refresh',
      );
      again.dispose();
    },
  );
  await check('multiple saved identities remain independent', () async {
    final store = MemoryAccountStore('trae'),
        http = FakeTrae(),
        app = owner(MemoryAccountStore('temp'), FakeTrae());
    app.dispose();
    final current = owner(store, http);
    await current.importCurrent(context());
    await current.importCurrent(context('b'));
    await current.automaticTick();
    expect(
      http.claims == 2 && (await current.accounts()).length == 2,
      'account isolation',
    );
    current.dispose();
  });
  await check('identity mismatch saves nothing', () async {
    final store = MemoryAccountStore('trae'),
        http = FakeTrae()..identityMismatch = true,
        app = owner(MemoryAccountStore('temp'), FakeTrae());
    app.dispose();
    final current = owner(store, http);
    await rejected(() => current.importCurrent(context()), 'identity_mismatch');
    expect(
      (await current.accounts()).isEmpty && http.claims == 0,
      'mismatched account',
    );
    current.dispose();
  });
  await check(
    'transient profile failure reuses pending authorization',
    () async {
      final store = MemoryAccountStore('trae'),
          http = FakeTrae()..failProfile = true;
      final app = owner(store, http);
      await rejected(() => app.importCurrent(context()), 'network_unavailable');
      expect(app.importPending, 'grant discarded');
      http.failProfile = false;
      await app.importCurrent();
      expect((await app.accounts()).length == 1, 'retry failed');
      app.dispose();
    },
  );
  await check(
    'uncertain claim uses read-only reconciliation and never repeats',
    () async {
      final store = MemoryAccountStore('trae'),
          http = FakeTrae()..loseReceipt = true;
      final app = owner(store, http);
      await app.importCurrent(context());
      await app.claim('a');
      app.dispose();
      final restored = owner(store, http);
      await restored.claim('a');
      expect(
        http.claims == 1 &&
            (await restored.accounts()).single.outcome == 'observedClaimed',
        'unknown replay',
      );
      restored.dispose();
    },
  );
  await check('intent persistence failure stops before claim', () async {
    final store = MemoryAccountStore('trae'), http = FakeTrae();
    final app = owner(store, http);
    await app.importCurrent(context());
    store.beforeWrite = () async {
      throw StateError('disk');
    };
    await rejected(() => app.claim('a'), 'storage_unavailable');
    expect(http.claims == 0, 'claim before commit');
    app.dispose();
  });
  await check(
    'independent rotated token persists before failed identity lookup',
    () async {
      final store = MemoryAccountStore('trae'), http = FakeTrae();
      final app = owner(store, http);
      await app.importCurrent(context());
      app.dispose();
      final a = store.data['accounts']['a'];
      a['owner'] = 'loongpass';
      a['expiresAt'] = instant - 1;
      a['refreshExpiresAt'] = instant + 86400000;
      a['refreshToken'] = 'synthetic-refresh';
      http.failProfile = true;
      final current = owner(store, http);
      await rejected(() => current.claim('a'), 'network_unavailable');
      current.dispose();
      expect(
        store.data['accounts']['a']['refreshToken'] == 'synthetic-refresh-next',
        'rotation lost',
      );
      http.failProfile = false;
      final restored = owner(store, http);
      await restored.claim('a');
      expect(http.refreshes == 1, 'old refresh replay');
      restored.dispose();
    },
  );
  await check(
    'earliest expiry uses remaining and excludes expired and feature packages',
    () async {
      final now = DateTime.fromMillisecondsSinceEpoch(instant, isUtc: true),
          sec = instant ~/ 1000;
      final summary = normalizeTraeCredits({
        'user_entitlement_pack_list': [
          package('a', 100, sec + 500, used: 80),
          package('b', 60, sec + 500),
          package('c', 4000, sec + 1000),
          package('old', 999, sec - 1),
          {
            'entitlement_base_info': {
              'quota': {'enable_solo': true},
            },
          },
        ],
      }, now);
      expect(
        summary.totalRemaining == 4080 &&
            summary.expiring.first.remaining == 80,
        'issued vs remaining',
      );
    },
  );
  print('$passed passed; $failed failed');
  if (failed > 0) exitCode = 1;
}
