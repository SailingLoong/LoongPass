import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../lib/rewards/loomy_provider.dart';
import '../lib/rewards/reward_provider.dart';

final instant = DateTime.utc(2026, 11, 6, 16);

void check(bool value, String name) {
  if (!value) throw StateError(name);
}

Future<void> fails(
  Future<Object?> Function() action,
  String code, {
  bool? rejected,
}) async {
  try {
    await action();
  } on RewardFailure catch (failure) {
    check(failure.code == code, 'failure classification $code');
    if (rejected != null) {
      check(
        (failure is RewardRejected) == rejected,
        'definitive rejection classification $code',
      );
    }
    return;
  }
  throw StateError('expected $code');
}

class Request {
  Request(this.method, this.url, this.headers, this.body);
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final Object? body;
}

class FakeTransport implements RewardTransport {
  FakeTransport(this.respond);
  final FutureOr<RewardReply> Function(Request) respond;
  final calls = <Request>[];

  @override
  Future<RewardReply> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Object? body,
  }) async {
    final request = Request(method, url, headers, body);
    calls.add(request);
    return await respond(request);
  }
}

RewardReply loomy(Map<String, dynamic> data) =>
    RewardReply(200, {'code': '000000', 'data': data});

RewardSession loomySession() => RewardSession(
  identity: 'official-loomy-1',
  label: 'Loomy account',
  credentials: {
    'access_token': 'synthetic-session',
    'userid': 'official-loomy-1',
    'expires_at': '1800000000000',
  },
);

Future<void> loomyLogin() async {
  final provider = LoomyProvider(now: () => instant);
  var sends = 0, completes = 0;
  final http = FakeTransport((r) {
    check(
      r.url.host == 'account.xfinfr.com' && r.method == 'POST',
      'CAccount route',
    );
    final body = r.body as String, payload = jsonDecode(body) as Map;
    final headers = r.headers;
    check(
      (payload['base'] as Map)['appid'] == 'GM3LOOMY' &&
          (payload['base'] as Map)['ua'] == 'Loomy|Desktop|Electron|macOS',
      'client identity',
    );
    check(
      headers['Content-MD5'] ==
          base64.encode(md5.convert(utf8.encode(body)).bytes),
      'exact body MD5',
    );
    final canonical =
        'POST\n${r.url.path}\n\n${headers['Content-MD5']}\n'
        'application/json\nFri, 06 Nov 2026 16:00:00 GMT\n${headers['Nonce']}\n\n';
    // Published desktop client configuration, not a user's account credential.
    final signature = base64.encode(
      Hmac(
        sha1,
        utf8.encode('zsak6eadrbawz683wf5r3m2snrwj868r'),
      ).convert(utf8.encode(canonical)).bytes,
    );
    check(
      headers['Date'] == 'Fri, 06 Nov 2026 16:00:00 GMT' &&
          headers['Authorization'] == 'account 2thryby66wxi53sk:$signature',
      'CAccount HMAC-SHA1 signature',
    );
    final param = payload['param'] as Map;
    check(
      param['ccode'] == '86' && param['phone'] == '13800138012',
      'SMS recipient',
    );
    if (r.url.path.endsWith('/sendMsgCode')) {
      sends++;
      check(param['expire'] == 300, 'SMS TTL');
      return loomy({'msgid': 'synthetic-message'});
    }
    completes++;
    check(
      r.url.path.endsWith('/checkCode') &&
          param['mcode'] == '123456' &&
          param['msgid'] == 'synthetic-message' &&
          param['expire'] == 1209600,
      'SMS completion payload',
    );
    if (completes == 1) return const RewardReply(503, {});
    return loomy({
      'session': 'synthetic-session',
      'userid': 'official-loomy-1',
    });
  });
  await fails(() => provider.beginLogin(http), 'invalid_phone');
  check(http.calls.isEmpty, 'missing phone never sends SMS');
  final flow = await provider.beginLogin(http, phone: '13800138012');
  check(
    sends == 1 && flow.url == null && await flow.poll() == null,
    'explicit SMS begin only',
  );
  await fails(
    () => flow.poll(verificationCode: '123456'),
    'network_unavailable',
  );
  final session = await flow.poll(verificationCode: '123456');
  check(
    session?.identity == 'official-loomy-1' &&
        !session!.label.contains('13800138012') &&
        session.label.contains('12'),
    'SMS stable identity and mask',
  );
  check(
    identical(await flow.poll(), session) && completes == 2 && sends == 1,
    'SMS grant cached for persistence retry',
  );
  flow.cancel();
  await fails(() => flow.poll(), 'cancelled');
}

Future<void> loomyRewards() async {
  final provider = LoomyProvider(now: () => instant);
  final records = FakeTransport((r) {
    check(
      r.method == 'GET' &&
          r.url.path == '/api/v2/points/records' &&
          r.url.queryParameters['direction'] == 'debit' &&
          r.url.queryParameters['granularity'] == 'chat' &&
          r.headers['token'] == 'synthetic-session' &&
          r.headers['Authorization'] == null,
      'read-only business token',
    );
    return loomy({
      'balance': 15000,
      'dailyBalance': 4992,
      'availableBalance': 19992,
    });
  });
  final credits = await provider.credits(records, loomySession());
  final dailyOnly = await provider.credits(
    FakeTransport(
      (r) => loomy({
        'data': {'dailyRemainingPoints': 123, 'dailyLimitPoints': 5000},
      }),
    ),
    loomySession(),
  );
  check(
    dailyOnly.totalRemaining == null &&
        dailyOnly.expiring.single.remaining == 123,
    'a daily-only snapshot must not invent a complete wallet balance',
  );
  check(
    credits.totalRemaining == 19992 &&
        credits.withoutExpiry == 15000 &&
        credits.expiring.single.remaining == 4992 &&
        credits.expiring.single.expiresAt == DateTime.utc(2026, 11, 7, 16),
    'separate permanent/daily amounts and UTC+8 day end',
  );
  final zero = await provider.credits(
    FakeTransport(
      (r) => loomy({
        'balance': 15000,
        'dailyBalance': 0,
        'availableBalance': 15000,
      }),
    ),
    loomySession(),
  );
  check(
    zero.totalRemaining == 15000 &&
        zero.withoutExpiry == 15000 &&
        zero.expiring.isEmpty,
    'zero daily leftovers',
  );
  final offer = await provider.inspect(records, loomySession(), '2026-11-07');
  check(
    offer.state == RewardState.available,
    'missing cycle needs explicit initialization',
  );
  final claim = FakeTransport((r) {
    check(
      r.method == 'POST' &&
          r.url.path == '/api/v1/points/first-login' &&
          (r.body as Map).isEmpty &&
          r.headers['token'] == 'synthetic-session',
      'daily initialization payload',
    );
    return loomy({
      'alreadyProcessed': false,
      'currentBalance': 19992,
      'permanentBalance': 15000,
      'dailyBalance': 4992,
      'dailyQuota': 5000,
      'dailyConsumed': 8,
      'dailyCycleDate': '2026-11-07',
      'registerReward': 5000,
    });
  });
  final outcome = await provider.claim(
    claim,
    loomySession(),
    offer,
    '2026-11-07',
  );
  check(
    outcome.state == RewardState.claimed && outcome.amount == null,
    'pool snapshot and one-off rewards are separate from new grant amount',
  );
  final current = FakeTransport(
    (r) => loomy({
      'balance': 15000,
      'dailyBalance': 0,
      'availableBalance': 15000,
      'dailyCycleDate': '2026-11-07',
    }),
  );
  check(
    (await provider.inspect(current, loomySession(), '2026-11-07')).state ==
        RewardState.already,
    'confirmed cycle with zero remaining',
  );
  for (final data in <Map<String, dynamic>>[
    {},
    {'alreadyProcessed': false, 'dailyQuota': 5000},
    {'alreadyProcessed': true, 'dailyCycleDate': '2026-11-06'},
    {'alreadyProcessed': 'true', 'dailyCycleDate': '2026-11-07'},
    {
      'alreadyProcessed': false,
      'dailyCycleDate': '2026-11-07',
      'dailyQuota': null,
    },
  ]) {
    await fails(
      () => provider.claim(
        FakeTransport((r) => loomy(data)),
        loomySession(),
        offer,
        '2026-11-07',
      ),
      'invalid_response',
    );
  }
  await fails(
    () => provider.credits(
      FakeTransport(
        (r) =>
            const RewardReply(200, {'code': '100002', 'desc': 'private raw'}),
      ),
      loomySession(),
    ),
    'login_required',
  );
  await fails(
    () => provider.credits(
      FakeTransport((r) => loomy({'balance': null, 'dailyBalance': null})),
      loomySession(),
    ),
    'invalid_response',
  );
  final mismatched = RewardSession(
    identity: 'other',
    label: 'account',
    credentials: loomySession().credentials,
  );
  await fails(() => provider.refresh(records, mismatched), 'identity_mismatch');
}

Future<void> main() async {
  for (final test in <String, Future<void> Function()>{
    'Loomy signed explicit SMS and retention': loomyLogin,
    'Loomy strict daily pool, unknown outcomes and balances': loomyRewards,
    'Loomy day rollover blocks stale offers': dailyEdges,
    'Loomy identity requirements and cancellation during login': loginEdges,
    'Loomy retains saved authorization until an official rejection':
        loomySessionLifetime,
    'Claim denials remain distinct from ambiguous writes': claimRejections,
  }.entries) {
    await test.value();
    print('PASS ${test.key}');
  }
}

Future<void> claimRejections() async {
  final provider = LoomyProvider(now: () => instant);
  final session = loomySession();
  final offer = RewardOffer(
    RewardState.available,
    data: {'day': '2026-11-07', 'identity': session.identity},
  );
  for (final status in [401, 403]) {
    await fails(
      () => provider.claim(
        FakeTransport((r) => RewardReply(status, {})),
        session,
        offer,
        '2026-11-07',
      ),
      'login_required',
      rejected: true,
    );
  }
  await fails(
    () => provider.claim(
      FakeTransport((r) => RewardReply(200, {'code': '100002'})),
      session,
      offer,
      '2026-11-07',
    ),
    'login_required',
    rejected: true,
  );
  await fails(
    () => provider.claim(
      FakeTransport((r) => RewardReply(200, {'code': '100001'})),
      session,
      offer,
      '2026-11-07',
    ),
    'request_rejected',
    rejected: true,
  );
  for (final status in [408, 503]) {
    await fails(
      () => provider.claim(
        FakeTransport((r) => RewardReply(status, {'code': '100002'})),
        session,
        offer,
        '2026-11-07',
      ),
      'network_unavailable',
      rejected: false,
    );
  }
  await fails(
    () => provider.claim(
      FakeTransport((r) => const RewardReply(400, {})),
      session,
      offer,
      '2026-11-07',
    ),
    'request_rejected',
    rejected: false,
  );
  await fails(
    () => provider.claim(
      FakeTransport((r) => const RewardReply(200, {})),
      session,
      offer,
      '2026-11-07',
    ),
    'request_rejected',
    rejected: false,
  );
  await fails(
    () => provider.claim(
      FakeTransport((r) => loomy({})),
      session,
      offer,
      '2026-11-07',
    ),
    'invalid_response',
    rejected: false,
  );
  await fails(
    () => provider.claim(
      FakeTransport((r) => RewardReply(200, {'code': '999999'})),
      session,
      offer,
      '2026-11-07',
    ),
    'request_rejected',
    rejected: false,
  );
  final noWrite = FakeTransport(
    (r) => throw StateError('rejected local offer was sent'),
  );
  await fails(
    () => provider.claim(noWrite, session, offer, '2026-11-06'),
    'activity_changed',
    rejected: true,
  );
  await fails(
    () => provider.claim(
      noWrite,
      session,
      RewardOffer(RewardState.available),
      '2026-11-07',
    ),
    'invalid_offer',
    rejected: true,
  );
  final missing = RewardSession(
    identity: session.identity,
    label: 'account',
    credentials: {},
  );
  await fails(
    () => provider.claim(noWrite, missing, offer, '2026-11-07'),
    'login_required',
    rejected: true,
  );
  check(
    noWrite.calls.isEmpty,
    'definitive local rejection dispatches no write',
  );
}

Future<void> loomySessionLifetime() async {
  var clock = instant;
  final provider = LoomyProvider(now: () => clock);
  final http = FakeTransport((request) {
    if (request.url.path.endsWith('/sendMsgCode')) {
      return loomy({'msgid': 'synthetic-message'});
    }
    if (request.url.path.endsWith('/checkCode')) {
      final param = (jsonDecode(request.body as String) as Map)['param'] as Map;
      check(param['expire'] == 1209600, 'requested CAccount wire lifetime');
      return loomy({
        'session': 'retained-session',
        'userid': 'official-loomy-1',
      });
    }
    check(
      request.url.path == '/api/v2/points/records' &&
          request.headers['token'] == 'retained-session',
      'saved session used for official read',
    );
    return loomy({
      'balance': 15000,
      'dailyBalance': 0,
      'availableBalance': 15000,
    });
  });
  final flow = await provider.beginLogin(http, phone: '13800138012');
  final authorized = (await flow.poll(verificationCode: '123456'))!;
  final saved = RewardSession(
    identity: authorized.identity,
    label: authorized.label,
    credentials: Map<String, dynamic>.from(
      jsonDecode(jsonEncode(authorized.credentials)) as Map,
    ),
  );
  flow.cancel();
  clock = instant.add(const Duration(days: 15));
  final reused = await provider.refresh(http, saved);
  check(
    (await provider.credits(http, reused)).totalRemaining == 15000,
    'saved session survives an unverified local 14-day boundary',
  );
  check(
    !reused.credentials.containsKey('expires_at'),
    'no estimated official expiry persisted',
  );

  final legacy = RewardSession(
    identity: saved.identity,
    label: saved.label,
    credentials: {
      ...saved.credentials,
      'expires_at': instant
          .add(const Duration(days: 14))
          .millisecondsSinceEpoch
          .toString(),
    },
  );
  final restored = await provider.refresh(http, legacy);
  check(
    !restored.credentials.containsKey('expires_at') &&
        (await provider.credits(http, restored)).totalRemaining == 15000,
    'previous estimated expiry is discarded while authorization is retained',
  );
  await fails(
    () => provider.credits(
      FakeTransport(
        (request) => const RewardReply(200, {
          'code': '100002',
          'desc': 'synthetic rejection',
        }),
      ),
      restored,
    ),
    'login_required',
  );
  check(
    http.calls
            .where((request) => request.url.path.endsWith('/sendMsgCode'))
            .length ==
        1,
    'passing local time never requests another SMS',
  );
}

Future<void> dailyEdges() async {
  final clock = instant.add(const Duration(days: 1));
  final noWrite = FakeTransport((r) => throw StateError('old offer sent'));
  final provider = LoomyProvider(now: () => clock);
  await fails(
    () => provider.claim(
      noWrite,
      loomySession(),
      RewardOffer(
        RewardState.available,
        data: {'day': '2026-11-07', 'identity': 'official-loomy-1'},
      ),
      '2026-11-07',
    ),
    'activity_changed',
  );
  check(noWrite.calls.isEmpty, 'rollover stops before the claim request');
}

Future<void> loginEdges() async {
  final smsResult = Completer<RewardReply>(), smsStarted = Completer<void>();
  final smsHttp = FakeTransport((r) {
    if (r.url.path.endsWith('/sendMsgCode')) return loomy({'msgid': 'message'});
    smsStarted.complete();
    return smsResult.future;
  });
  final sms = await LoomyProvider(
    now: () => instant,
  ).beginLogin(smsHttp, phone: '13800138012');
  final smsCancelled = fails(
    () => sms.poll(verificationCode: '123456'),
    'cancelled',
  );
  await smsStarted.future;
  sms.cancel();
  smsResult.complete(
    loomy({'session': 'synthetic-session', 'userid': 'official-loomy-1'}),
  );
  await smsCancelled;
  final missingSmsHttp = FakeTransport(
    (r) => r.url.path.endsWith('/sendMsgCode')
        ? loomy({'msgid': 'message'})
        : loomy({'session': 'token'}),
  );
  final smsMissing = await LoomyProvider(
    now: () => instant,
  ).beginLogin(missingSmsHttp, phone: '13800138012');
  await fails(
    () => smsMissing.poll(verificationCode: '123456'),
    'invalid_identity',
  );
  await fails(() => smsMissing.poll(), 'invalid_identity');
  check(
    missingSmsHttp.calls
            .where((r) => r.url.path.endsWith('/checkCode'))
            .length ==
        1,
    'successful SMS session retained when identity is missing',
  );
  smsMissing.cancel();
}
