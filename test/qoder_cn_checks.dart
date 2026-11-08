import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/qoder_device_accounts.dart';

void expect(bool yes, String msg) {
  if (!yes) throw StateError(msg);
}

Future<void> rejects(Future<Object?> Function() f, String code) async {
  try {
    await f();
  } on QoderAccountError catch (e) {
    expect(e.code == code, 'wrong code ${e.code}');
    return;
  }
  throw StateError('accepted');
}

class Native implements QoderNative {
  int revision = 0;
  String payload = '{}';
  bool failSave = false;
  void Function()? afterSave;
  Completer<void>? commitDelay;
  bool cancelled = false;
  bool committed = false;
  bool loseCommitReply = false, uncertain = false;
  @override
  Future<Map<String, dynamic>> call(String m, Map<String, dynamic> a) async {
    if (m == 'newGrant')
      return {
        'verifier': 'v' * 43,
        'challenge': 'c' * 43,
        'nonce': '11111111-1111-4111-8111-111111111111',
        'machineId': '22222222-2222-4222-8222-222222222222',
      };
    if (m == 'cancelGrant') {
      if (!committed) cancelled = true;
      return {
        'status': uncertain
            ? 'unknown'
            : committed
            ? 'completed'
            : 'cancelled',
      };
    }
    if (m == 'read') return {'revision': revision, 'payload': payload};
    if (m == 'compareAndSet' || m == 'commitGrant') {
      if (m == 'commitGrant') {
        if (commitDelay != null) await commitDelay!.future;
        if (cancelled) throw StateError('cancelled');
      }
      if (failSave) throw StateError('SECRET');
      if (a['expectedRevision'] != revision) throw StateError('CAS');
      payload = a['payload'];
      revision++;
      if (m == 'commitGrant' && loseCommitReply) {
        uncertain = true;
        throw StateError('readback failed');
      }
      if (m == 'commitGrant') committed = true;
      final savedRevision = revision;
      afterSave?.call();
      return {'revision': savedRevision};
    }
    throw StateError('method');
  }
}

class Transport implements QoderTransport {
  final calls = <String>[];
  bool wrongUid = false, pending = false, failPost = false;
  int serverMs = 100000;
  Completer<QoderResponse>? delayed;
  List<Map<String, dynamic>> rows = [
    {
      'campaignId': 'free',
      'benefit': {'kind': 'CREDITS', 'amount': 100},
      'actionType': 'CLAIM_BENEFIT',
      'claimStatus': 'CLAIMABLE',
    },
  ];
  @override
  Future<QoderResponse> send(
    String method,
    Uri url,
    String? bearer,
    Map<String, dynamic>? body, {
    bool Function()? isCurrent,
  }) async {
    calls.add('$method ${url.path}');
    expect(url.host == 'openapi.qoder.com.cn', 'wrong region');
    if (url.path.endsWith('/poll')) {
      if (delayed != null) return delayed!.future;
      if (pending) return QoderResponse(404, {});
      return grant();
    }
    if (url.path.endsWith('/userinfo'))
      return QoderResponse(200, {'id': wrongUid ? 'other' : 'account-a'});
    if (url.path.endsWith('/me/usage'))
      return QoderResponse(200, {
        'uid': 'account-a',
        'displayMode': 'qoder',
        'qoderUsage': {
          'addOnQuota': {'total': 100, 'used': 25},
        },
      });
    if (method == 'POST') {
      if (failPost) throw StateError('SECRET');
      return QoderResponse(200, {'status': 'CLAIMED', 'campaignId': 'free'});
    }
    return QoderResponse(200, {
      'uid': 'account-a',
      'campaigns': rows,
    }, serverMs: serverMs);
  }

  QoderResponse grant() => QoderResponse(200, {
    'token': 'synthetic-access',
    'refresh_token': 'synthetic-refresh',
    'user_id': 'account-a',
    'expires_in': 3600,
  });
}

Future<void> main() async {
  var passed = 0, failed = 0;
  Future<void> test(String name, Future<void> Function() f) async {
    try {
      await f();
      passed++;
      print('PASS $name');
    } catch (_) {
      failed++;
      print('FAIL $name');
    }
  }

  QoderDeviceAccounts client(Native n, Transport t, {int Function()? now}) =>
      QoderDeviceAccounts(native: n, transport: t, nowMs: now ?? () => 100000);
  Future<void> login(QoderDeviceAccounts q) async {
    await q.startLogin();
    expect(await q.pollLogin() == 'account-a', 'login');
  }

  await test(
    'disabled rewards still refresh credits and startup is read only',
    () async {
      final n = Native(), t = Transport();
      final owner = client(n, t);
      try {
        await login(owner);
        await owner.setAutomatic('account-a', false);
        await owner.automaticTick();
        expect(
          owner.credits('account-a')?.addOnRemaining == 75,
          'disabled reward policy suppressed usage',
        );
        final before = t.calls.length;
        owner.startAutomatic();
        await Future<void>.delayed(Duration.zero);
        expect(
          t.calls.skip(before).any((p) => p.endsWith('/me/usage')),
          'startup did not query credits',
        );
        expect(
          !t.calls.skip(before).any((p) => p.startsWith('POST')),
          'startup credit read submitted a reward',
        );
      } finally {
        owner.dispose();
      }
    },
  );

  await test(
    'real command contract grant URL contains challenge not verifier',
    () async {
      final n = Native(), t = Transport();
      final q = client(n, t);
      final s = await q.startLogin();
      expect(
        s.url.host == 'qoder.cn' && s.url.path == '/device/selectAccounts',
        'url',
      );
      expect(!s.url.queryParameters.containsKey('verifier'), 'verifier leaked');
      expect(t.calls.isEmpty && n.revision == 0, 'premature action');
    },
  );
  await test(
    'verified login persists only after independent identity',
    () async {
      final n = Native(), t = Transport();
      final q = client(n, t);
      await login(q);
      expect((await q.accounts()).single == 'account-a', 'account');
      expect(t.calls.length == 2 && n.revision == 1, 'ownership');
    },
  );
  await test('identity mismatch cannot save', () async {
    final n = Native(), t = Transport()..wrongUid = true;
    final q = client(n, t);
    await q.startLogin();
    await rejects(() => q.pollLogin(), 'identity_mismatch');
    expect(n.revision == 0, 'saved');
  });
  await test('poll pending rate limited', () async {
    var now = 100000;
    final n = Native(), t = Transport()..pending = true;
    final q = client(n, t, now: () => now);
    await q.startLogin();
    await q.pollLogin();
    await q.pollLogin();
    expect(t.calls.length == 1, 'repeated poll');
    now += 1000;
    await q.pollLogin();
    expect(t.calls.length == 2, 'next poll');
  });
  await test('cancel wins over pending response', () async {
    final n = Native(), t = Transport()..delayed = Completer<QoderResponse>();
    final q = client(n, t);
    await q.startLogin();
    final work = q.pollLogin();
    await Future<void>.delayed(Duration.zero);
    q.cancelLogin();
    t.delayed!.complete(t.grant());
    await rejects(() => work, 'cancelled');
    expect(n.revision == 0, 'saved cancelled');
  });
  await test('expired login does not request', () async {
    var now = 100000;
    final n = Native(), t = Transport();
    final q = client(n, t, now: () => now);
    await q.startLogin();
    now += 300000;
    await rejects(() => q.pollLogin(), 'expired');
    expect(t.calls.isEmpty, 'expired call');
  });
  await test('unknown native save never re-polls consumed grant', () async {
    final n = Native()..failSave = true, t = Transport();
    final q = client(n, t);
    await q.startLogin();
    await rejects(() => q.pollLogin(), 'storage_unavailable');
    await rejects(() => q.pollLogin(), 'login_required');
    expect(t.calls.length == 2, 'retried');
  });
  await test('successful claim durably reserved and not repeated', () async {
    final n = Native(), t = Transport();
    final q = client(n, t);
    await login(q);
    final rows = await q.claim('account-a');
    expect(rows.single['outcome'] == 'claimedDeltaUnknown', 'claim');
    await q.claim('account-a');
    expect(t.calls.where((e) => e.startsWith('POST')).length == 1, 'repeated');
  });
  await test('unknown POST remains blocked across restart', () async {
    final n = Native(), t = Transport()..failPost = true;
    final q = client(n, t);
    await login(q);
    expect(
      (await q.claim('account-a')).single['outcome'] == 'unknown',
      'unknown',
    );
    final restarted = client(n, t);
    await restarted.claim('account-a');
    expect(
      t.calls.where((e) => e.startsWith('POST')).length == 1,
      'unknown repeated',
    );
  });
  await test('paid, terms and duplicate activities never POST', () async {
    final n = Native(), t = Transport();
    final q = client(n, t);
    await login(q);
    t.rows = [
      {
        'campaignId': 'paid',
        'actionType': 'CLAIM_BENEFIT',
        'claimStatus': 'CLAIMABLE',
        'creditsCost': 1,
      },
      {
        'campaignId': 'terms',
        'actionType': 'CLAIM_BENEFIT',
        'claimStatus': 'CLAIMABLE',
        'termsAcceptanceRequired': true,
      },
      {
        'campaignId': 'dup',
        'actionType': 'CLAIM_BENEFIT',
        'claimStatus': 'CLAIMABLE',
      },
      {
        'campaignId': 'dup',
        'actionType': 'CLAIM_BENEFIT',
        'claimStatus': 'CLAIMABLE',
      },
    ];
    await q.claim('account-a');
    expect(!t.calls.any((e) => e.startsWith('POST')), 'conditional claim');
  });
  await test('persisted malformed account blocks before network', () async {
    final n = Native()
          ..payload = jsonEncode({
            'accounts': {
              'account-a': {'token': 'x'},
            },
            'claims': {},
          }),
        t = Transport();
    await rejects(() => client(n, t).claim('account-a'), 'invalid_storage');
    expect(t.calls.isEmpty, 'network');
  });

  await test('cancel during native grant generation cancels start', () async {
    final n = SlowNative(), t = Transport();
    final q = client(n, t);
    final start = q.startLogin();
    q.cancelLogin();
    n.ready.complete();
    await rejects(() => start, 'cancelled');
    expect(t.calls.isEmpty, 'network');
  });
  await test('zero pending claim marker survives account relogin', () async {
    final n = Native(), t = Transport()..failPost = true;
    final q = client(n, t);
    await login(q);
    await q.claim('account-a');
    await login(q);
    await q.claim('account-a');
    expect(
      t.calls.where((e) => e.startsWith('POST')).length == 1,
      'relogin reset ledger',
    );
  });
  await test('production transport rejects other origins before I/O', () async {
    await rejects(
      () => QoderHttp().send(
        'GET',
        Uri.parse('https://openapi.qoder.sh/api/v1/userinfo'),
        null,
        null,
      ),
      'invalid_source',
    );
  });
  await test('native reservation failure means no POST', () async {
    final n = Native(), t = Transport();
    final q = client(n, t);
    await login(q);
    n.failSave = true;
    await rejects(() => q.claim('account-a'), 'storage_unavailable');
    expect(
      !t.calls.any((e) => e.startsWith('POST')),
      'sent before durable intent',
    );
  });
  await test('malformed campaignKey cannot be claimed', () async {
    final n = Native(), t = Transport();
    final q = client(n, t);
    await login(q);
    t.rows.single['campaignKey'] = {'bad': true};
    await q.claim('account-a');
    expect(!t.calls.any((e) => e.startsWith('POST')), 'bad campaign key sent');
  });

  await test('nested verification challenge prevents any claim', () async {
    final n = Native(), t = ChallengeTransport();
    final q = client(n, t);
    await login(q);
    await rejects(() => q.claim('account-a'), 'verification_required');
    expect(!t.calls.any((e) => e.startsWith('POST')), 'challenge bypassed');
  });

  await test(
    'confirmed claim permits verified nonoverlapping window',
    () async {
      final n = Native(), t = Transport();
      final q = client(n, t);
      await login(q);
      t.rows.single.addAll({
        'campaignKey': 'round1',
        'startAt': 90,
        'endAt': 110,
      });
      await q.claim('account-a');
      t.rows.single.addAll({
        'campaignKey': 'round2',
        'startAt': 110,
        'endAt': 130,
      });
      t.serverMs = 120000;
      await q.claim('account-a');
      expect(
        t.calls.where((e) => e.startsWith('POST')).length == 2,
        'new window blocked',
      );
    },
  );
  await test('unknown claim blocks even advanced window', () async {
    final n = Native(), t = Transport()..failPost = true;
    final q = client(n, t);
    await login(q);
    t.rows.single.addAll({'startAt': 90, 'endAt': 110});
    await q.claim('account-a');
    t.rows.single.addAll({'startAt': 110, 'endAt': 130});
    t.serverMs = 120000;
    await q.claim('account-a');
    expect(
      t.calls.where((e) => e.startsWith('POST')).length == 1,
      'unknown advance allowed',
    );
  });
  await test(
    'confirmed then independent CLAIMED then CLAIMABLE can rearm',
    () async {
      final n = Native(), t = Transport();
      final q = client(n, t);
      await login(q);
      await q.claim('account-a');
      t.rows.single['claimStatus'] = 'CLAIMED';
      await q.claim('account-a');
      t.rows.single['claimStatus'] = 'CLAIMABLE';
      await q.claim('account-a');
      expect(
        t.calls.where((e) => e.startsWith('POST')).length == 2,
        'observed transition blocked',
      );
    },
  );

  await test('older login cannot overwrite later persisted state', () async {
    final n = Native(), t = Transport()..delayed = Completer<QoderResponse>();
    final q = client(n, t);
    await q.startLogin();
    final work = q.pollLogin();
    await Future<void>.delayed(Duration.zero);
    n.revision++;
    t.delayed!.complete(t.grant());
    await rejects(() => work, 'storage_unavailable');
    expect(n.payload == '{}', 'old grant saved');
  });
  await test('cancel wins before native grant commit executes', () async {
    final n = Native()..commitDelay = Completer<void>(), t = Transport();
    final q = client(n, t);
    await q.startLogin();
    final work = q.pollLogin();
    await Future<void>.delayed(Duration.zero);
    q.cancelLogin();
    n.commitDelay!.complete();
    await rejects(() => work, 'storage_unavailable');
    expect(n.revision == 0, 'cancelled commit saved');
  });
  await test(
    'account changed after durable reservation prevents POST',
    () async {
      final n = Native(), t = Transport();
      final q = client(n, t);
      await login(q);
      n.afterSave = () {
        n.revision++;
      };
      await rejects(() => q.claim('account-a'), 'source_changed');
      expect(!t.calls.any((e) => e.startsWith('POST')), 'stale POST');
    },
  );
  await test(
    'token expires while reservation persists prevents POST',
    () async {
      var now = 100000;
      final n = Native(), t = Transport();
      final q = client(n, t, now: () => now);
      await login(q);
      n.afterSave = () {
        now = 999999999;
      };
      await rejects(() => q.claim('account-a'), 'identity_expired');
      expect(!t.calls.any((e) => e.startsWith('POST')), 'expired POST');
    },
  );

  await test(
    'write-success readback-failure cancellation remains unknown',
    () async {
      final n = Native()..loseCommitReply = true, t = Transport();
      final q = client(n, t);
      await q.startLogin();
      await rejects(() => q.pollLogin(), 'storage_unavailable');
      expect(n.revision == 1, 'write did not happen');
      expect(
        await q.cancelLogin() == 'unknown',
        'false cancelled after uncertain save',
      );
      expect(
        (await q.accounts()).contains('account-a'),
        'saved credential lost',
      );
    },
  );
  await test('cancel after confirmed commit reports completed', () async {
    final n = Native(), t = Transport();
    final q = client(n, t);
    await login(q);
    expect(
      await q.cancelLogin() == 'completed',
      'false cancelled after commit',
    );
  });
  await test(
    'rotation survives profile failure and restart without old refresh replay',
    () async {
      var now = 100000;
      final n = Native(), t = RefreshTransport();
      final q = client(n, t, now: () => now);
      await login(q);
      q.dispose();
      now += 3600001;
      t.failProfile = true;
      final current = client(n, t, now: () => now);
      await rejects(() => current.claim('account-a'), 'network_error');
      current.dispose();
      expect(
        jsonDecode(n.payload)['accounts']['account-a']['refreshToken'] ==
            'synthetic-rotated',
        'refresh lost',
      );
      t.failProfile = false;
      final restored = client(n, t, now: () => now);
      await restored.claim('account-a');
      expect(t.refreshes == 1, 'old refresh replayed');
      restored.dispose();
    },
  );
  await test('invalid refresh grant is persisted and never retried', () async {
    var now = 100000;
    final n = Native(), t = RefreshTransport();
    final q = client(n, t, now: () => now);
    await login(q);
    now += 3600001;
    t.refreshStatus = 401;
    await rejects(() => q.claim('account-a'), 'identity_expired');
    await rejects(() => q.claim('account-a'), 'identity_expired');
    expect(
      t.refreshes == 1 && !t.calls.any((v) => v.endsWith('/claim')),
      'invalid refresh retried',
    );
    q.dispose();
  });
  await test(
    'transient profile keeps consumed login token beyond device-code window',
    () async {
      var now = 100000;
      final n = Native(), t = RefreshTransport()..failProfile = true;
      final q = client(n, t, now: () => now);
      await q.startLogin();
      await rejects(() => q.pollLogin(), 'network_error');
      now += 301000;
      t.failProfile = false;
      expect(await q.pollLogin() == 'account-a', 'retained login failed');
      expect(
        t.calls.where((v) => v.endsWith('/poll')).length == 1,
        'consumed grant polled twice',
      );
      q.dispose();
    },
  );
  for (final refreshBeforeObservation in [false, true]) {
    await test(
      'confirmed campaign reopens across token rotation ($refreshBeforeObservation)',
      () async {
        var now = 100000;
        final n = Native(), t = RefreshTransport();
        final q = client(n, t, now: () => now);
        await login(q);
        await q.claim('account-a');
        if (refreshBeforeObservation) now += 3600001;
        t.rows.single['claimStatus'] = 'CLAIMED';
        await q.claim('account-a');
        if (!refreshBeforeObservation) now += 3600001;
        t.rows.single['claimStatus'] = 'CLAIMABLE';
        await q.claim('account-a');
        expect(t.refreshes == 1, 'credentials must rotate');
        expect(
          t.calls.where((s) => s.endsWith('/claim')).length == 2,
          'verified next round blocked',
        );
        q.dispose();
      },
    );
  }
  await test(
    'closing during durable reservation withholds claim dispatch',
    () async {
      final n = Native(), t = Transport();
      final q = client(n, t);
      await login(q);
      n.afterSave = q.dispose;
      await rejects(() => q.claim('account-a'), 'closed');
      expect(
        t.calls.every((s) => !s.endsWith('/claim')),
        'closed owner dispatched',
      );
      final claims = jsonDecode(n.payload)['claims'] as Map;
      expect(
        claims.values.single['state'] == 'pending',
        'durable intent must survive',
      );
    },
  );
  await test(
    'production transport rechecks admission after connection wait',
    () async {
      final client = WaitingClient();
      var current = true;
      await HttpOverrides.runZoned(() async {
        final request = QoderHttp().send(
          'POST',
          Uri.https(
            QoderRegion.cn.apiHost,
            '/sash/api/v1/me/campaigns/synthetic/claim',
          ),
          'synthetic-token',
          null,
          isCurrent: () => current,
        );
        current = false;
        client.connection.complete(client.request);
        await rejects(() => request, 'operation_expired');
        expect(
          client.request.aborted && !client.request.dispatched,
          'expired connection dispatched',
        );
      }, createHttpClient: (_) => client);
    },
  );
  print('$passed passed; $failed failed');
  if (failed > 0) exitCode = 1;
}

class SlowNative extends Native {
  final ready = Completer<void>();
  @override
  Future<Map<String, dynamic>> call(String m, Map<String, dynamic> a) async {
    if (m == 'newGrant') await ready.future;
    return super.call(m, a);
  }
}

class WaitingClient implements HttpClient {
  final connection = Completer<HttpClientRequest>();
  final request = WaitingRequest();
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      connection.future;
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class WaitingRequest implements HttpClientRequest {
  bool aborted = false, dispatched = false;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborted = true;
  }

  @override
  Future<HttpClientResponse> close() async {
    dispatched = true;
    throw StateError('Unexpected dispatch');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class ChallengeTransport extends Transport {
  @override
  Future<QoderResponse> send(
    String m,
    Uri u,
    String? b,
    Map<String, dynamic>? j, {
    bool Function()? isCurrent,
  }) async {
    final r = await super.send(m, u, b, j, isCurrent: isCurrent);
    if (u.path.endsWith("/campaigns"))
      r.body["data"] = {"code": "CHALLENGE_REQUIRED"};
    return r;
  }
}

class RefreshTransport extends Transport {
  int refreshes = 0, refreshStatus = 200;
  bool failProfile = false;
  @override
  Future<QoderResponse> send(
    String method,
    Uri url,
    String? bearer,
    Map<String, dynamic>? body, {
    bool Function()? isCurrent,
  }) async {
    if (url.path.endsWith('/refresh')) {
      expect(
        method == 'POST' &&
            bearer == null &&
            body?.keys.single == 'refresh_token',
        'refresh wire',
      );
      refreshes++;
      return QoderResponse(refreshStatus, {
        'device_token': 'synthetic-new',
        'refresh_token': 'synthetic-rotated',
        'expires_in': 3600,
      });
    }
    if (url.path.endsWith('/userinfo') && failProfile)
      throw const QoderAccountError('network_error');
    return super.send(method, url, bearer, body, isCurrent: isCurrent);
  }
}
