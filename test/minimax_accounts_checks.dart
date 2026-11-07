// Synthetic credentials, isolated atomic document, fake HTTP; no real credentials.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../lib/source_digest.dart';
import '../lib/minimax_accounts.dart';
import '../lib/minimax_http.dart';
import '../lib/minimax_oauth.dart';
import 'memory_account_store.dart';
import 'synthetic_fixture.dart' show MiniMaxRegion;
import 'synthetic_fixture.dart' as fixture;

Map<String, dynamic> panel({bool today = true, int status = 2}) => {
  'scene': 1,
  'days': [
    for (var i = 1; i <= 7; i++)
      {
        'day_no': i,
        'points': 10,
        'status': i == 1 ? status : 1,
        'is_today': i == 1 && today,
      },
  ],
};
MiniMaxReply response(Map<String, dynamic> data) => MiniMaxReply(200, {
  'base_resp': {'status_code': 0},
  'data': data,
});

class FakeHttp extends MiniMaxHttp {
  int creditCalls = 0;
  final calls = <MiniMaxEndpoint>[];
  MiniMaxReply profile = const MiniMaxReply(200, {
    'statusInfo': {'code': 0},
    'data': {
      'userInfo': {'realUserID': 'server-user', 'name': 'Synthetic'},
    },
  });
  MiniMaxReply status = response(panel());
  MiniMaxReply receipt = response({
    'claim_id': 'synthetic-receipt',
    'claim_result': 1,
    'day_no': 1,
    'points': 10,
    'expire_at_ms': 999999,
    'panel': panel(status: 3),
  });
  int refreshCalls = 0;
  MiniMaxReply refreshed = const MiniMaxReply(200, {
    'access_token': 'synthetic-new',
    'refresh_token': 'synthetic-rotated',
    'expires_in': 3600,
    'token_type': 'Bearer',
    'scope': 'agent.default',
  });
  @override
  Future<MiniMaxReply> oauth(
    String path,
    String region,
    Map<String, String> body, {
    bool Function()? isCurrent,
  }) async {
    expect(body['grant_type'] == 'refresh_token', 'unexpected OAuth');
    refreshCalls++;
    return refreshed;
  }

  bool loseClaim = false;
  Future<void> Function(MiniMaxEndpoint)? pause;
  @override
  Future<MiniMaxReply> credits({
    required String accessToken,
    required String region,
    required String userId,
    required int pageNumber,
    bool Function()? isCurrent,
  }) async {
    creditCalls++;
    return const MiniMaxReply(200, {'details': [], 'total_count': 0});
  }

  @override
  Future<MiniMaxReply> send(
    MiniMaxEndpoint e, {
    required String accessToken,
    required String region,
    String? userId,
    bool Function()? isCurrent,
  }) async {
    if (accessToken != 'synthetic-access' && accessToken != 'synthetic-new')
      throw StateError('wrong token');
    await pause?.call(e);
    if (!(isCurrent?.call() ?? true)) throw StateError('request_cancelled');
    calls.add(e);
    if (e == MiniMaxEndpoint.claim && loseClaim)
      throw StateError('synthetic private transport detail');
    return e == MiniMaxEndpoint.profile
        ? profile
        : e == MiniMaxEndpoint.status
        ? status
        : receipt;
  }
}

void expect(bool v, String s) {
  if (!v) throw StateError(s);
}

Future<void> reject(Future<Object?> Function() f, [String? code]) async {
  try {
    await f();
  } on MiniMaxAccountError catch (e) {
    expect(code == null || e.code == code, 'wrong error ${e.code}');
    return;
  }
  throw StateError('accepted');
}

Future<void> main() async {
  var passed = 0, failed = 0;
  final root = await Directory(
    await Directory.systemTemp.resolveSymbolicLinks(),
  ).createTemp('loongpass-minimax-synthetic-');
  var index = 0;
  var time = 100000;
  Future<void> check(String name, Future<void> Function(Directory) body) async {
    final d = await root.createTemp('${index++}-');
    await Process.run('/bin/chmod', ['700', d.path]);
    try {
      await body(d);
      passed++;
      stdout.writeln('PASS $name');
    } catch (e) {
      failed++;
      stdout.writeln('FAIL $name: $e');
    } finally {
      time = 100000;
    }
  }

  final documents = <String, MemoryAccountStore>{};
  MiniMaxAccountStore store(Directory d, {Future<void> Function()? sync}) {
    final doc = documents.putIfAbsent(d.path, () => MemoryAccountStore(d.path));
    doc.afterWrite = sync;
    return MiniMaxAccountStore(doc);
  }

  Future<MiniMaxCredential> read() => Future.value(
    MiniMaxCredential.parse(
      fixture.bytes(),
      sourcePath: fixture.path(MiniMaxRegion.cn),
      region: 'cn',
      nowMs: time,
    ),
  );
  MiniMaxAccounts service(
    Directory d,
    FakeHttp h, {
    Future<void> Function()? sync,
  }) => MiniMaxAccounts(
    store: store(d, sync: sync),
    http: h,
    nowMs: () => time,
  );
  Future<MiniMaxAccount> imported(MiniMaxAccounts s) async =>
      s.save(await s.verifySource(read, confirmed: true), confirmed: true);
  await check('credits refresh without reward opt-in and after reward errors', (
    d,
  ) async {
    final h = FakeHttp(), s = service(d, h);
    try {
      final a = await imported(s);
      await s.setAutomatic(a.id, false);
      await s.automaticTick();
      expect(
        h.creditCalls == 1 && s.credits(a.id)?.totalRemaining == 0,
        'disabled reward policy suppressed credit read',
      );
      await s.setAutomatic(a.id, true);
      h.status = const MiniMaxReply(503, null);
      await s.automaticTick();
      expect(h.creditCalls == 2, 'failed reward status suppressed credit read');
      expect(
        !h.calls.contains(MiniMaxEndpoint.claim),
        'reading credits claimed a reward',
      );
    } finally {
      s.dispose();
    }
  });
  await check(
    'verified identity and credentials save atomically; DTO redacts',
    (d) async {
      final h = FakeHttp(), s = service(d, FakeHttp());
      final a = await imported(s);
      expect(a.uid == 'server-user', 'local subject trusted');
      final raw = jsonEncode(documents[d.path]!.data);
      expect(
        raw.contains('synthetic-access') && raw.contains('server-user'),
        'atomic account missing',
      );
      expect(
        !raw.contains('synthetic-refresh'),
        'imported client refresh copied',
      );
      expect(
        !jsonEncode(a.toJson()).contains('synthetic-access'),
        'DTO credential leak',
      );
      expect((await s.list()).length == 1 && h.calls.isEmpty, 'not saved');
      s.dispose();
    },
  );
  await check('read/verify and save separately require confirmation', (
    d,
  ) async {
    final h = FakeHttp();
    final s = service(d, h);
    await reject(
      () => s.verifySource(read, confirmed: false),
      'ConfirmationRequired',
    );
    expect(h.calls.isEmpty, 'unconfirmed HTTP');
    final v = await s.verifySource(read, confirmed: true);
    await reject(() => s.save(v, confirmed: false), 'ConfirmationRequired');
    expect((await s.list()).isEmpty, 'unconfirmed save');
    s.dispose();
  });
  await check('bad profile cannot become account', (d) async {
    final h = FakeHttp()..profile = const MiniMaxReply(401, null);
    final s = service(d, h);
    await reject(() => s.verifySource(read, confirmed: true), 'NeedsLogin');
    expect((await s.list()).isEmpty, 'bad profile saved');
    s.dispose();
  });
  await check('source replacement before save is rejected', (d) async {
    final h = FakeHttp();
    final s = service(d, h);
    var changed = false;
    Future<MiniMaxCredential> source() async => MiniMaxCredential.parse(
      fixture.bytes(row: fixture.record()..['generation'] = (changed ? 10 : 9)),
      sourcePath: fixture.path(MiniMaxRegion.cn),
      region: 'cn',
      nowMs: time,
    );
    final v = await s.verifySource(source, confirmed: true);
    changed = true;
    await reject(() => s.save(v, confirmed: true), 'SourceChanged');
    s.dispose();
  });
  await check('saved import cannot be replayed', (d) async {
    final s = service(d, FakeHttp());
    final v = await s.verifySource(read, confirmed: true);
    await s.save(v, confirmed: true);
    await reject(() => s.save(v, confirmed: true), 'ImportCompleted');
    s.dispose();
  });
  await check('claim records real receipt and same-day never sends twice', (
    d,
  ) async {
    final h = FakeHttp();
    final s = service(d, h);
    s.dispose();
    final live = service(d, h);
    final a = await imported(live);
    final result = await live.claim(a.id);
    expect(
      result.status == 'claimed' && result.points == 10,
      'missing receipt',
    );
    await live.claim(a.id);
    expect(
      h.calls.where((v) => v == MiniMaxEndpoint.claim).length == 1,
      'duplicate POST',
    );
    live.dispose();
  });
  await check('uncertain claim survives restart and next day', (d) async {
    final h = FakeHttp()..loseClaim = true;
    final s = service(d, h);
    final a = await imported(s);
    expect((await s.claim(a.id)).status == 'unknown', 'timeout not unknown');
    s.dispose();
    time = 86500000;
    final next = service(d, h);
    expect((await next.claim(a.id)).status == 'unknown', 'pending lost');
    expect(
      h.calls.where((v) => v == MiniMaxEndpoint.claim).length == 1,
      'retry unknown',
    );
    next.dispose();
    time = 100000;
  });
  await check('automatic opt-in persists and requires today eligibility', (
    d,
  ) async {
    final h = FakeHttp();
    final s = service(d, h);
    s.dispose();
    final live = service(d, h);
    final a = await imported(live);
    await live.automaticTick();
    expect(!h.calls.contains(MiniMaxEndpoint.claim), 'auto default on');
    await live.setAutomatic(a.id, true);
    h.status = response(panel(today: false));
    await live.automaticTick();
    expect(!h.calls.contains(MiniMaxEndpoint.claim), 'automatic backfill');
    h.status = response(panel());
    await live.automaticTick();
    expect(
      h.calls.where((e) => e == MiniMaxEndpoint.claim).length == 1,
      'automatic not dispatched',
    );
    live.dispose();
  });
  await check('metadata persistence failure prevents POST', (d) async {
    var failSync = false;
    final h = FakeHttp();
    final s = service(
      d,
      h,
      sync: () async {
        if (failSync) throw StateError('disk');
      },
    );
    final a = await imported(s);
    failSync = true;
    await reject(() => s.claim(a.id), 'StorageUnavailable');
    expect(
      !h.calls.contains(MiniMaxEndpoint.claim),
      'POST before durable intent',
    );
    s.dispose();
  });
  await check('concurrent claims one owner', (d) async {
    final h = FakeHttp();
    final gate = Completer<void>();
    h.pause = (e) async {
      if (e == MiniMaxEndpoint.status) await gate.future;
    };
    final s = service(d, h);
    final a = await imported(s);
    final first = s.claim(a.id);
    await Future<void>.delayed(Duration.zero);
    await reject(() => s.claim(a.id), 'Busy');
    gate.complete();
    await first;
    expect(
      h.calls.where((e) => e == MiniMaxEndpoint.claim).length == 1,
      'parallel POST',
    );
    s.dispose();
  });
  await check('dispose during profile verification prevents save', (d) async {
    final h = FakeHttp();
    final gate = Completer<void>();
    h.pause = (e) async {
      if (e == MiniMaxEndpoint.profile) await gate.future;
    };
    final s = service(d, h);
    final v = s
        .verifySource(read, confirmed: true)
        .then<Object?>((value) => value, onError: (Object error) => error);
    await Future<void>.delayed(Duration.zero);
    s.dispose();
    gate.complete();
    final error = await v;
    expect(
      error is MiniMaxAccountError && error.code == 'Closed',
      'late profile was not closed',
    );
  });
  await check('expired import cannot verify network', (d) async {
    final h = FakeHttp();
    final s = service(d, h);
    await reject(
      () => s.verifySource(
        () async => MiniMaxCredential.parse(
          fixture.bytes(row: fixture.record()..['expiresAtMs'] = time),
          sourcePath: fixture.path(MiniMaxRegion.cn),
          region: 'cn',
          nowMs: time,
        ),
        confirmed: true,
      ),
    );
    expect(h.calls.isEmpty, 'expired request');
    s.dispose();
  });
  await check('real-user ID missing rejects local fallback', (d) async {
    final h = FakeHttp()
      ..profile = const MiniMaxReply(200, {
        'data': {
          'userInfo': {'subject': 'not-verified'},
        },
      });
    final s = service(d, h);
    await reject(
      () => s.verifySource(read, confirmed: true),
      'InvalidResponse',
    );
    s.dispose();
  });
  await check('HTTP claim 401 stays unknown and never retries', (d) async {
    final h = FakeHttp()..receipt = const MiniMaxReply(401, null);
    final s = service(d, h);
    final a = await imported(s);
    expect((await s.claim(a.id)).status == 'unknown', '401 blind success');
    await s.claim(a.id);
    expect(
      h.calls.where((v) => v == MiniMaxEndpoint.claim).length == 1,
      '401 replay',
    );
    s.dispose();
  });
  await check('credential expires during status: no claim dispatch', (d) async {
    final h = FakeHttp();
    final s = service(d, h);
    final a = await imported(s);
    h.pause = (e) async {
      if (e == MiniMaxEndpoint.status) time = 1000000;
    };
    await reject(() => s.claim(a.id), 'NeedsLogin');
    expect(!h.calls.contains(MiniMaxEndpoint.claim), 'expired credential sent');
    time = 100000;
    s.dispose();
  });
  await check('day changes after intent fsync: no stale-day claim', (d) async {
    final h = FakeHttp();
    var syncs = 0;
    final s = service(
      d,
      h,
      sync: () async {
        syncs++;
        if (syncs == 2) time = 86500000;
      },
    );
    final a = await imported(s);
    await reject(() => s.claim(a.id));
    expect(!h.calls.contains(MiniMaxEndpoint.claim), 'old day intent sent');
    time = 100000;
    s.dispose();
  });
  await check('reimport preserves unresolved claim and disables automatic', (
    d,
  ) async {
    final h = FakeHttp()..loseClaim = true;
    final s = service(d, h);
    final a = await imported(s);
    await s.setAutomatic(a.id, true);
    await s.claim(a.id);
    final b = await imported(s);
    expect(
      b.status == 'unknown' && !b.automatic,
      'reimport erased claim or copied consent',
    );
    await s.claim(b.id);
    expect(
      h.calls.where((e) => e == MiniMaxEndpoint.claim).length == 1,
      'reimport replayed',
    );
    s.dispose();
  });
  await check(
    'parallel verified imports cannot overwrite newer saved account',
    (d) async {
      final s = service(d, FakeHttp());
      final a = await s.verifySource(read, confirmed: true),
          b = await s.verifySource(read, confirmed: true);
      await s.save(a, confirmed: true);
      await reject(() => s.save(b, confirmed: true), 'SourceChanged');
      expect((await s.list()).length == 1, 'duplicate account');
      s.dispose();
    },
  );
  await check('automatic opt-in restored after reopening service', (d) async {
    final h = FakeHttp();
    final s = service(d, h);
    final a = await imported(s);
    await s.setAutomatic(a.id, true);
    s.dispose();
    final next = service(d, h);
    await next.automaticTick();
    expect(
      h.calls.where((e) => e == MiniMaxEndpoint.claim).length == 1,
      'persisted auto ignored',
    );
    next.dispose();
  });
  await check('malformed panel stops before POST', (d) async {
    final h = FakeHttp()..status = response({'scene': 1, 'days': []});
    final s = service(d, h);
    final a = await imported(s);
    await reject(() => s.claim(a.id), 'InvalidResponse');
    expect(
      !h.calls.contains(MiniMaxEndpoint.claim),
      'invalid status dispatched',
    );
    s.dispose();
  });
  await check('malformed receipt is unknown rather than success', (d) async {
    final h = FakeHttp()..receipt = response({'claim_result': 1, 'points': 10});
    final s = service(d, h);
    final a = await imported(s);
    expect(
      (await s.claim(a.id)).status == 'unknown',
      'malformed receipt success',
    );
    await s.claim(a.id);
    expect(
      h.calls.where((e) => e == MiniMaxEndpoint.claim).length == 1,
      'invalid receipt retry',
    );
    s.dispose();
  });
  await check(
    'same JSON at different source home cannot change verified credential',
    (d) async {
      final s = service(d, FakeHttp());
      const other = '/other/auth';
      final otherKey =
          'com.minimax.mcode.oauth.prod.cn\u0000${base64Url.encode(sourceSha256(utf8.encode('$other\u0000mcode-public'))).replaceAll('=', '')}';
      final raw = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'schemaVersion': 1,
            'records': {
              fixture.key(MiniMaxRegion.cn): fixture.record(),
              otherKey: fixture.record()..['accessToken'] = 'synthetic-new',
            },
          }),
        ),
      );
      var changed = false;
      Future<MiniMaxCredential> source() async => MiniMaxCredential.parse(
        raw,
        sourcePath: changed
            ? '$other/prod/cn/mcode-public/auth.json'
            : fixture.path(MiniMaxRegion.cn),
        region: 'cn',
        nowMs: time,
      );
      final v = await s.verifySource(source, confirmed: true);
      changed = true;
      await reject(() => s.save(v, confirmed: true), 'SourceChanged');
      s.dispose();
    },
  );
  await check('expiry during claim connection prevents dispatch', (d) async {
    final h = FakeHttp();
    final s = service(d, h);
    final a = await imported(s);
    h.pause = (e) async {
      if (e == MiniMaxEndpoint.claim) time = 1000000;
    };
    expect(
      (await s.claim(a.id)).status == 'unknown',
      'cancelled intent not unknown',
    );
    expect(!h.calls.contains(MiniMaxEndpoint.claim), 'expired POST dispatched');
    s.dispose();
  });
  await check(
    'automatic completion refreshes once and isolates callback failures',
    (d) async {
      var callbacks = 0;
      final s = MiniMaxAccounts(
        store: store(d),
        onAutomaticFinished: () async {
          callbacks++;
          throw StateError('UI failure');
        },
      );
      await s.automaticTick();
      expect(callbacks == 1, 'missing or repeated completion');
      await s.automaticTick();
      expect(callbacks == 2, 'callback poisoned tick');
      s.dispose();
    },
  );
  await check('disposed automatic tick does not notify UI', (d) async {
    final h = FakeHttp(), gate = Completer<void>();
    var callbacks = 0;
    final s = MiniMaxAccounts(
      store: store(d),
      http: h,
      nowMs: () => time,
      onAutomaticFinished: () {
        callbacks++;
      },
    );
    final a = await imported(s);
    await s.setAutomatic(a.id, true);
    h.pause = (e) async {
      if (e == MiniMaxEndpoint.status) await gate.future;
    };
    final tick = s.automaticTick();
    await Future<void>.delayed(Duration.zero);
    await s.automaticTick();
    expect(callbacks == 0, 'skipped overlapping tick notified');
    s.dispose();
    gate.complete();
    await tick;
    expect(callbacks == 0, 'disposed callback');
  });
  await check('claim owner serializes save and automatic changes', (d) async {
    final h = FakeHttp(), gate = Completer<void>();
    final s = service(d, h);
    final a = await imported(s);
    final next = await s.verifySource(read, confirmed: true);
    h.pause = (e) async {
      if (e == MiniMaxEndpoint.status) await gate.future;
    };
    final claiming = s.claim(a.id);
    await Future<void>.delayed(Duration.zero);
    try {
      await reject(() => s.save(next, confirmed: true), 'Busy');
      await reject(() => s.setAutomatic(a.id, true), 'Busy');
    } finally {
      gate.complete();
      await claiming;
      s.dispose();
    }
  });
  Future<MiniMaxAccount> authorized(MiniMaxAccounts s) async {
    final credential = MiniMaxCredential.authorization(
      MiniMaxOAuthToken('synthetic-access', time + 600000, 'synthetic-refresh'),
      'cn',
    );
    return s.save(
      await s.verifySource(() async => credential, confirmed: true),
      confirmed: true,
      automatic: true,
    );
  }

  await check(
    'refresh rotates and persists before identity failure, restart uses new token',
    (d) async {
      final h = FakeHttp(), s = service(d, FakeHttp());
      await authorized(s);
      s.dispose();
      final live = service(d, h);
      time += 600001;
      h.profile = const MiniMaxReply(503, null);
      final id = (await live.list()).single.id;
      await reject(() => live.claim(id), 'InvalidResponse');
      expect(
        h.refreshCalls == 1 && !h.calls.contains(MiniMaxEndpoint.claim),
        'refresh/profile ordering',
      );
      final row = (documents[d.path]!.data['accounts'] as Map).values.single;
      expect(
        row['refreshToken'] == 'synthetic-rotated' &&
            row['identityVerified'] == false,
        'rotation not saved',
      );
      live.dispose();
      h.profile = FakeHttp().profile;
      final restored = service(d, h);
      await restored.claim(id);
      expect(
        h.refreshCalls == 1 &&
            h.calls.where((e) => e == MiniMaxEndpoint.claim).length == 1,
        'old refresh replay',
      );
      restored.dispose();
    },
  );
  await check('temporary refresh failure retains still-valid access', (
    d,
  ) async {
    final h = FakeHttp(), s = service(d, h);
    final a = await authorized(s);
    time += 550000;
    h.refreshed = const MiniMaxReply(503, null);
    await s.claim(a.id);
    expect(
      h.refreshCalls == 1 && h.calls.contains(MiniMaxEndpoint.claim),
      'valid access discarded',
    );
    s.dispose();
  });
  await check('explicit invalid grant requires login, never claims', (d) async {
    final h = FakeHttp(), s = service(d, h);
    final a = await authorized(s);
    time += 600001;
    h.refreshed = const MiniMaxReply(400, {'error': 'invalid_grant'});
    await reject(() => s.claim(a.id), 'NeedsLogin');
    await reject(() => s.claim(a.id), 'NeedsLogin');
    expect(
      h.refreshCalls == 1 && !h.calls.contains(MiniMaxEndpoint.claim),
      'invalid grant replay',
    );
    s.dispose();
  });
  await check('lost refresh-save acknowledgement reuses persisted rotation', (
    d,
  ) async {
    final h = FakeHttp(), s = service(d, h);
    final a = await authorized(s);
    time += 600001;
    documents[d.path]!.afterWrite = () async {
      throw StateError('lost ack');
    };
    await reject(() => s.claim(a.id), 'StorageUnavailable');
    documents[d.path]!.afterWrite = null;
    await s.claim(a.id);
    expect(h.refreshCalls == 1, 'rotation repeated after committed write');
    s.dispose();
  });
  await check('inference shares account lock and observes owner shutdown', (
    d,
  ) async {
    final h = FakeHttp(), s = service(d, h);
    final a = await authorized(s);
    final entered = Completer<void>(), release = Completer<void>();
    final inference = s.withInferenceAuthorization(a.id, (
      region,
      token,
      current,
    ) async {
      expect(
        region == 'cn' && token == 'synthetic-access',
        'wrong inference credential',
      );
      entered.complete();
      await release.future;
      return current();
    });
    await entered.future;
    await reject(() => s.claim(a.id), 'Busy');
    await reject(() => s.setAutomatic(a.id, false), 'Busy');
    s.dispose();
    release.complete();
    expect(!await inference, 'closed owner retained inference authority');
  });
  await check('inference reuses persisted refresh before dispatch', (d) async {
    final h = FakeHttp(), s = service(d, h);
    final a = await authorized(s);
    time += 550000;
    await s.withInferenceAuthorization(a.id, (region, token, current) async {
      final row = (documents[d.path]!.data['accounts'] as Map).values.single;
      expect(
        token == 'synthetic-new' && row['accessToken'] == token,
        'dispatch preceded durable rotation',
      );
      expect(
        h.refreshCalls == 1 && current(),
        'inference bypassed refresh owner',
      );
    });
    s.dispose();
  });
  stdout.writeln('RESULT $passed passed, $failed failed');
  await root.delete(recursive: true);
  exitCode = failed == 0 ? 0 : 1;
}
