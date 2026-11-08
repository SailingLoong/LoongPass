// Synthetic rotating grants and native document faults; no account access.
import 'dart:convert';
import 'dart:io';

import '../lib/minimax_accounts.dart';
import '../lib/minimax_http.dart';
import '../lib/minimax_oauth.dart';
import 'memory_account_store.dart';
import 'minimax_accounts_checks.dart' as f;

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> rejected(Future<Object?> Function() use, String expected) async {
  try {
    await use();
  } on MiniMaxAccountError catch (e) {
    check(e.code == expected, 'expected $expected, received ${e.code}');
    return;
  }
  throw StateError('operation unexpectedly succeeded');
}

class Store extends MemoryAccountStore {
  bool failReservation = false, loseReservationAck = false;
  bool failRotation = false, loseRotationAck = false;
  Store(super.identity);

  @override
  Future<void> write(int expectedRevision, Map<String, dynamic> next) async {
    final row = (next['accounts'] as Map).values.single as Map;
    final reservation = row['refreshPending'] == true;
    final rotation = row['accessToken'] == 'synthetic-new' && !reservation;
    if (failReservation && reservation || failRotation && rotation)
      throw StateError('synthetic disk unavailable');
    await super.write(expectedRevision, next);
    if (loseReservationAck && reservation || loseRotationAck && rotation)
      throw StateError('synthetic write acknowledgement lost');
  }

  Map<String, dynamic> get row =>
      (data['accounts'] as Map).values.single as Map<String, dynamic>;
}

class Http extends f.FakeHttp {
  final Store store;
  bool loseRefresh = false;
  bool? reservedAtSend;
  Future<void> Function()? beforeRefreshReply;
  Http(this.store);

  @override
  Future<MiniMaxReply> oauth(
    String path,
    String region,
    Map<String, String> body, {
    bool Function()? isCurrent,
  }) async {
    reservedAtSend = store.row['refreshPending'] == true;
    await beforeRefreshReply?.call();
    if (loseRefresh) {
      refreshCalls++;
      throw StateError('synthetic unknown refresh outcome');
    }
    return super.oauth(path, region, body, isCurrent: isCurrent);
  }
}

class Rig {
  final Store store;
  late final Http http = Http(store);
  int now = 100000;
  late MiniMaxAccounts owner = open();
  late MiniMaxAccount saved;
  Rig(String name) : store = Store('minimax-refresh-$name');

  MiniMaxAccounts open() => MiniMaxAccounts(
    store: MiniMaxAccountStore(store),
    http: http,
    nowMs: () => now,
  );

  Future<void> login() async {
    final credential = MiniMaxCredential.authorization(
      MiniMaxOAuthToken('synthetic-access', 700000, 'synthetic-refresh'),
      'cn',
    );
    saved = await owner.save(
      await owner.verifySource(() async => credential, confirmed: true),
      confirmed: true,
      automatic: true,
    );
  }

  void restart() {
    owner.dispose();
    owner = open();
  }

  Future<String> read() => owner.withInferenceAuthorization(saved.id, (
    region,
    token,
    current,
    registration,
  ) async {
    check(current(), 'lease was not current');
    return token;
  });

  Future<void> refuse(String token) => owner.rejectInferenceAuthorization(
    saved.id,
    saved.registrationId!,
    token,
  );
}

Future<void> main() async {
  var failures = 0;
  Future<void> test(String name, Future<void> Function(Rig) use) async {
    final rig = Rig(name);
    try {
      await rig.login();
      await use(rig);
      print('PASS $name');
    } catch (e) {
      failures++;
      print('FAIL $name: $e');
    } finally {
      rig.owner.dispose();
    }
  }

  for (final failure in ['lost-reply', 'http503', 'malformed-success']) {
    await test('unknown $failure refresh is never replayed after restart', (
      r,
    ) async {
      r.now = 650000; // Still-valid access, inside the ordinary renewal window.
      r.http.loseRefresh = failure == 'lost-reply';
      if (failure == 'http503') {
        r.http.refreshed = const MiniMaxReply(503, null);
      } else if (failure == 'malformed-success') {
        r.http.refreshed = const MiniMaxReply(200, {
          'access_token': 'synthetic-new',
          'refresh_token': 'synthetic-rotated',
          'expires_in': 3600,
          'token_type': 'Bearer',
          'scope': 'unrelated.scope',
        });
      }
      await rejected(r.read, 'NetworkUnavailable');
      check(
        r.http.reservedAtSend == true,
        'refresh preceded durable reservation',
      );
      check(
        r.store.row['refreshPending'] == true,
        'unknown rotation was forgotten',
      );
      r.restart();
      r.http.loseRefresh = false;
      r.http.refreshed = f.FakeHttp().refreshed;
      await rejected(r.read, 'NeedsLogin');
      check(
        r.http.refreshCalls == 1,
        'restart spent the same refresh grant twice',
      );
      check(
        r.http.calls.length == 1,
        'unknown rotation dispatched an account API',
      );
    });
  }

  await test('reservation save failure sends no refresh POST', (r) async {
    r.now = 650000;
    r.store.failReservation = true;
    await rejected(r.read, 'StorageUnavailable');
    check(
      r.http.refreshCalls == 0,
      'refresh sent before reservation committed',
    );
    r.store.failReservation = false;
    check(
      await r.read() == 'synthetic-new',
      'unsent grant could not be reserved later',
    );
    check(
      r.http.refreshCalls == 1 && r.http.reservedAtSend == true,
      'later independent renewal was not reserved exactly once',
    );
  });

  await test('lost reservation acknowledgement fails closed before POST', (
    r,
  ) async {
    r.now = 650000;
    r.store.loseReservationAck = true;
    await rejected(r.read, 'StorageUnavailable');
    check(
      r.http.refreshCalls == 0,
      'lost reservation acknowledgement sent refresh',
    );
    r.store.loseReservationAck = false;
    r.restart();
    await rejected(r.read, 'NeedsLogin');
    check(
      r.http.refreshCalls == 0,
      'restart treated a pending reservation as unused',
    );
  });

  await test('returned rotation survives failed save in the current owner', (
    r,
  ) async {
    r.now = 650000;
    r.store.failRotation = true;
    await rejected(r.read, 'StorageUnavailable');
    check(r.http.refreshCalls == 1, 'expected a single refresh transmission');
    r.store.failRotation = false;
    check(
      await r.read() == 'synthetic-new',
      'returned replacement was discarded',
    );
    check(
      r.http.refreshCalls == 1 && r.store.row['refreshPending'] != true,
      'save retry spent the old refresh grant',
    );
  });

  await test(
    'a returned forced rotation is saved before enforcing its recovery limit',
    (r) async {
      await r.refuse('synthetic-access');
      r.store.failRotation = true;
      await rejected(r.read, 'StorageUnavailable');
      r.store.failRotation = false;
      check(
        await r.read() == 'synthetic-new',
        'recovery limit discarded a known replacement',
      );
      check(
        r.http.refreshCalls == 1,
        'resuming forced rotation spent another grant',
      );
    },
  );

  await test(
    'restart after an uncommitted token save cannot spend the old grant',
    (r) async {
      r.now = 650000;
      r.store.failRotation = true;
      await rejected(r.read, 'StorageUnavailable');
      r.store.failRotation = false;
      r.restart();
      await rejected(r.read, 'NeedsLogin');
      check(
        r.http.refreshCalls == 1,
        'restart repeated an acknowledged rotation',
      );
    },
  );

  await test(
    'lost token-save acknowledgement keeps registration and claim journals',
    (r) async {
      r.store.row.addAll({
        'status': 'unknown',
        'operation': {
          'id': 'unknown-current',
          'day': '2026-11-08',
          'state': 'unknown',
        },
        'previousSuccessfulOperation': {
          'id': 'claimed-previous',
          'day': '2026-11-07',
          'state': 'claimed',
          'points': 10,
          'confirmedAtMs': 100000,
        },
        'unresolvedOperations': [
          {'id': 'unknown-archived', 'day': '2026-11-06', 'state': 'unknown'},
        ],
      });
      final previous = jsonEncode(r.store.row);
      r.now = 650000;
      r.store.loseRotationAck = true;
      await rejected(r.read, 'StorageUnavailable');
      r.store.loseRotationAck = false;
      r.restart();
      check(
        await r.read() == 'synthetic-new',
        'committed replacement was not recovered',
      );
      final old = jsonDecode(previous) as Map;
      for (final key in [
        'id',
        'registrationId',
        'automatic',
        'policyRevision',
        'operation',
        'previousSuccessfulOperation',
        'unresolvedOperations',
      ]) {
        check(
          jsonEncode(r.store.row[key]) == jsonEncode(old[key]),
          'rotation changed $key',
        );
      }
      check(
        (await r.owner.list()).single.latestClaim?.amount == 10,
        'rotation changed absolute prior reward points',
      );
      check(
        r.http.refreshCalls == 1 &&
            r.store.row['generation'] == 2 &&
            r.store.row['refreshToken'] == 'synthetic-rotated' &&
            r.store.row['refreshPending'] != true,
        'committed rotation was replayed or lost',
      );
    },
  );

  await test('a rejected replacement cannot force an endless rotation loop', (
    r,
  ) async {
    await r.refuse('synthetic-access');
    check(
      await r.read() == 'synthetic-new',
      'first forced recovery was not allowed',
    );
    await r.refuse('synthetic-new');
    r.restart();
    await rejected(r.read, 'NeedsLogin');
    check(r.http.refreshCalls == 1, 'rejected replacement spent another grant');
    r.now = 3650000; // Replacement expires at 3700000: ordinary renewal is due.
    r.http.refreshed = const MiniMaxReply(200, {
      'access_token': 'synthetic-access',
      'refresh_token': 'synthetic-next',
      'expires_in': 3600,
      'token_type': 'Bearer',
      'scope': 'agent.default',
    });
    check(
      await r.read() == 'synthetic-access',
      'ordinary expiry renewal was suppressed',
    );
    check(
      r.http.refreshCalls == 2 &&
          r.store.row['refusalRecoveryAttempted'] != true,
      'ordinary renewal did not clear the forced-recovery allowance',
    );
    await r.refuse('synthetic-access');
    r.http.refreshed = f.FakeHttp().refreshed;
    check(
      await r.read() == 'synthetic-new' && r.http.refreshCalls == 3,
      'a later ordinary grant could not recover one independent refusal',
    );
  });

  await test('a newer registration wins over a staged stale rotation', (
    r,
  ) async {
    r.now = 650000;
    r.http.beforeRefreshReply = () async {
      r.store.row.addAll({
        'generation': 2,
        'registrationId': 'synthetic-new-registration',
        'expiresAtMs': 4300000,
        'refreshToken': 'synthetic-new-registration-refresh',
        'accessRejected': false,
      });
      r.store.row.remove('refreshPending');
    };
    await rejected(r.read, 'SourceChanged');
    r.http.beforeRefreshReply = null;
    check(
      await r.read() == 'synthetic-access',
      'stale rotation obscured the newer registration',
    );
    check(
      r.http.refreshCalls == 1 &&
          r.store.row['registrationId'] == 'synthetic-new-registration',
      'stale returned credentials overwrote a newer registration',
    );
  });

  for (final endpoint in ['profile', 'status']) {
    await test('bare account $endpoint 403 is not a login-required failure', (
      r,
    ) async {
      if (endpoint == 'profile') {
        r.restart();
        r.http.profile = const MiniMaxReply(403, null);
        await rejected(r.read, 'InvalidResponse');
      } else {
        r.http.status = const MiniMaxReply(403, null);
        await rejected(() => r.owner.claim(r.saved.id), 'InvalidResponse');
        await r.owner.automaticTick();
        check(
          r.store.row['status'] != 'needsLogin',
          'ordinary403 requested login',
        );
      }
      check(
        r.http.refreshCalls == 0 && r.store.row['accessRejected'] != true,
        'bare403 renewed or rejected an otherwise usable grant',
      );
    });
  }

  exitCode = failures == 0 ? 0 : 1;
}
