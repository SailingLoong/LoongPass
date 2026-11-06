import 'dart:async';

import '../lib/zcode_api.dart';
import '../lib/zcode_activity_accounts.dart';
import '../lib/zcode_rewards.dart';
import 'memory_account_store.dart';

const now = 1793900000000;
const context = <String, String>{
  'version': '3.17.2',
  'platform': 'darwin-arm64',
  'deviceMid': '11111111-2222-4333-8444-555555555555',
  'language': 'zh-CN',
  'timezone': 'Asia/Shanghai',
};
void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Map<String, dynamic> envelope(Map<String, dynamic> data) => {
  'code': 0,
  'data': data,
};
Map<String, dynamic> plan(String instance, {int end = 1793903600}) => {
  'plan_id': 'night',
  'user_plan_id': instance,
  'status': 'active',
  'starts_at': 1793890000,
  'ends_at': end,
};

class FakeZcode implements ZcodeTransport {
  String userId = 'same-id';
  int claims = 0, polls = 0, balanceCalls = 0;
  int serverTime = now ~/ 1000;
  bool stringTimes = false;
  bool emptyPreview = false;
  bool loseReply = false, revealReceipt = true, failBalance = false;
  int claimCode = 0;
  int claimHttp = 200;
  bool acceptVerification = false;
  final received = <ZcodeRequest>[];
  final balances = <String, List<Map<String, dynamic>>>{};
  @override
  Future<ZcodeReply> send(ZcodeRequest r, {bool Function()? isCurrent}) async {
    if (isCurrent?.call() == false) throw const ZcodeFailure('cancelled');
    received.add(r);
    if (r.path == ZcodeApi.initPath) {
      return ZcodeReply(
        200,
        envelope({
          'authorize_url': r.body!['provider'] == 'bigmodel'
              ? 'https://bigmodel.cn/login?flow=synthetic'
              : 'https://z.ai/authorize?flow=synthetic',
          'flow_id': 'synthetic',
          'expires_at': now ~/ 1000 + 600,
          'poll_interval_sec': 1,
        }),
      );
    }
    if (r.path.startsWith(ZcodeApi.pollPrefix)) {
      polls++;
      final provider = received
          .firstWhere((v) => v.path == ZcodeApi.initPath)
          .body!['provider'];
      return ZcodeReply(
        200,
        envelope({
          'status': 'ready',
          'user': {'user_id': userId, 'name': 'Synthetic'},
          'token': userId == 'same-id'
              ? 'synthetic-$provider'
              : 'synthetic-$provider-$userId',
          provider: {
            'access_token': 'provider-secret',
            'refresh_token': 'refresh-secret',
          },
        }),
      );
    }
    final token = r.token;
    if (r.path == ZcodeApi.configPath)
      return ZcodeReply(
        200,
        envelope({
          'configs': {
            'captcha': {
              'enabled': true,
              'region': 'cn',
              'prefix': 'synthetic',
              'sceneId': 'scene',
            },
          },
        }),
      );
    if (r.path == ZcodeApi.balancePath) {
      balanceCalls++;
      if (failBalance) throw const ZcodeFailure('network_unavailable');
      return ZcodeReply(
        200,
        envelope({
          'server_time': serverTime,
          'plans': revealReceipt ? balances[token] ?? [] : [],
          'balances': [],
        }),
      );
    }
    if (r.path == ZcodeApi.previewPath)
      return ZcodeReply(
        200,
        emptyPreview ? {'code': 0} : envelope({'plans': []}),
      );
    if (r.path == ZcodeApi.marketingPath)
      return ZcodeReply(
        200,
        envelope({
          'deliveries': [
            {
              'resource_position': 'popup',
              'priority': 1,
              'popup': {
                'buttons': [
                  {
                    'action': {
                      'type': 'claim_zcode_plan',
                      'args': {'plan_id': 'night'},
                    },
                  },
                ],
              },
            },
          ],
        }),
      );
    if (r.path == ZcodeApi.claimPath) {
      claims++;
      if (claimCode != 0 && !(acceptVerification && r.verification != null))
        return ZcodeReply(claimHttp, {'code': claimCode});
      balances[token] = [plan('receipt-$claims', end: serverTime + 3600)];
      if (stringTimes)
        balances[token]!.single['ends_at'] = '${serverTime + 3600}';
      if (loseReply) throw const ZcodeFailure('network_unavailable');
      return ZcodeReply(200, envelope({'plan': plan('receipt-$claims')}));
    }
    throw StateError('Unexpected endpoint');
  }
}

Future<ZcodeActivityAccounts> account(
  MemoryAccountStore store,
  FakeZcode http, {
  String family = 'bigmodel',
  Map<String, String> deviceContext = context,
}) async {
  final a = ZcodeActivityAccounts(
    store: store,
    api: ZcodeApi(http),
    now: () => now,
  );
  await a.beginAuthorization(family, deviceContext);
  await a.pollAuthorizationOnce();
  return a;
}

Future<void> main() async {
  final store = MemoryAccountStore('zcode-test');
  final http = FakeZcode();
  var a = await account(store, http);
  final id = (await a.accounts()).single.id;
  check(http.claims == 0, 'login must not synchronously consume activity');
  check(
    RegExp(r'^[0-9a-f]{64}$').hasMatch(http.received.first.token),
    'OAuth polling token must use official lowercase hex format',
  );
  await a.inspect(id);
  check(
    http.claims == 0 && (await a.accounts()).single.status == 'claimable',
    'preview is read only',
  );
  await a.claim(id);
  check(
    http.claims == 1 && (await a.accounts()).single.status == 'claimed',
    'marketing-only offer must claim and reconcile',
  );
  a.dispose();
  a = ZcodeActivityAccounts(store: store, api: ZcodeApi(http), now: () => now);
  await a.tick();
  check(http.claims == 1, 'restart must preserve reward receipts');
  check(
    (await a.accounts()).single.automatic,
    'restart must preserve automatic policy',
  );
  a.dispose();

  final futureHttp = FakeZcode();
  futureHttp.balances['synthetic-bigmodel'] = [
    {...plan('future'), 'starts_at': now ~/ 1000 + 60},
  ];
  final future = await account(MemoryAccountStore('future'), futureHttp);
  await future.claim((await future.accounts()).single.id);
  check(
    futureHttp.claims == 0,
    'already issued future entitlement must not be claimed again',
  );
  future.dispose();

  final partialHttp = FakeZcode()..emptyPreview = true;
  final partial = await account(
    MemoryAccountStore('partial-discovery'),
    partialHttp,
  );
  await partial.claim((await partial.accounts()).single.id);
  check(
    partialHttp.claims == 1,
    'missing preview data must not suppress explicit marketing offers',
  );
  partial.dispose();

  final pendingStore = MemoryAccountStore('pending');
  final uncertain = FakeZcode()
    ..loseReply = true
    ..revealReceipt = false;
  var pending = await account(pendingStore, uncertain);
  final pid = (await pending.accounts()).single.id;
  await pending.claim(pid);
  check(
    (await pending.accounts()).single.status == 'pending',
    'lost result must stay pending',
  );
  pending.dispose();

  final lateHttp = FakeZcode()
    ..loseReply = true
    ..revealReceipt = false;
  final late = await account(MemoryAccountStore('late-receipt'), lateHttp);
  final lid = (await late.accounts()).single.id;
  await late.claim(lid);
  lateHttp.revealReceipt = true;
  lateHttp.serverTime += 86400;
  lateHttp.balances['synthetic-bigmodel']!.single['status'] = 'expired';
  await late.inspect(lid);
  check(
    (await late.accounts()).single.status == 'claimed',
    'an expired new receipt still proves the prior attempt completed',
  );
  lateHttp.loseReply = false;
  await late.claim(lid);
  check(
    lateHttp.claims == 2 && (await late.accounts()).single.status == 'claimed',
    'a new server offer may reuse an expired plan ID',
  );
  late.dispose();
  pending = ZcodeActivityAccounts(
    store: pendingStore,
    api: ZcodeApi(uncertain),
    now: () => now,
  );
  await pending.claim(pid);
  check(uncertain.claims == 1, 'restart must not resend uncertain POST');
  uncertain.revealReceipt = true;
  await pending.inspect(pid);
  check(
    (await pending.accounts()).single.status == 'claimed',
    'new matching receipt resolves uncertainty',
  );
  pending.dispose();

  final failedStore = MemoryAccountStore('write-failure');
  final savedHttp = FakeZcode();
  final saving = ZcodeActivityAccounts(
    store: failedStore,
    api: ZcodeApi(savedHttp),
    now: () => now,
  );
  await saving.beginAuthorization('bigmodel', context);
  failedStore.beforeWrite = () async => throw StateError('disk unavailable');
  try {
    await saving.pollAuthorizationOnce();
  } catch (_) {}
  failedStore.beforeWrite = null;
  await saving.pollAuthorizationOnce();
  check(
    savedHttp.polls == 1 && (await saving.accounts()).length == 1,
    'reuse obtained auth after failed save',
  );
  failedStore.beforeWrite = () async => throw StateError('disk unavailable');
  try {
    await saving.claim((await saving.accounts()).single.id);
  } catch (_) {}
  check(savedHttp.claims == 0, 'no POST if durable pending cannot be saved');
  saving.dispose();

  final captchaHttp = FakeZcode()
    ..claimCode = 3007
    ..claimHttp = 400;
  final captchaStore = MemoryAccountStore('captcha');
  final captcha = await account(captchaStore, captchaHttp);
  final cid = (await captcha.accounts()).single.id;
  await captcha.claim(cid);
  await captcha.tick();
  check(
    captchaHttp.claims == 1 &&
        (await captcha.accounts()).single.status == 'verificationRequired',
    'HTTP 400 / code 3007 is a definite captcha rejection, not an uncertain POST',
  );
  captcha.dispose();
  captchaStore.data['accounts'][cid]['claims']['night']['state'] = 'pending';
  captchaStore.data['accounts'][cid]['status'] = 'pending';
  final restoredCaptcha = ZcodeActivityAccounts(
    store: captchaStore,
    api: ZcodeApi(captchaHttp),
    now: () => now,
  );
  await restoredCaptcha.tick();
  check(
    captchaHttp.claims == 1 &&
        (await restoredCaptcha.accounts()).single.status ==
            'verificationRequired',
    'recover recorded captcha rejection after restart without another POST',
  );
  restoredCaptcha.dispose();

  final verifiedHttp = FakeZcode()
    ..claimCode = 3007
    ..claimHttp = 400
    ..acceptVerification = true;
  final verifiedStore = MemoryAccountStore('verified');
  final verified = await account(verifiedStore, verifiedHttp);
  final vid = (await verified.accounts()).single.id;
  var prompts = 0;
  await verified.claim(
    vid,
    verify: (config) async {
      prompts++;
      check(
        verifiedStore.data['accounts'][vid]['claims']['night']['state'] ==
            'verificationRequired',
        'persist definite rejection before human verification',
      );
      return 'synthetic-human-proof';
    },
  );
  check(
    prompts == 1 &&
        verifiedHttp.claims == 2 &&
        (await verified.accounts()).single.status == 'claimed',
    'one manual verification can resolve a definite rejection with official receipt',
  );
  final proofRequest = verifiedHttp.received.lastWhere(
    (r) => r.verification != null,
  );
  check(
    proofRequest.path == ZcodeApi.claimPath &&
        proofRequest.context['deviceMid'] == context['deviceMid'] &&
        proofRequest.verification!.headers['X-Aliyun-Captcha-Verify-Region'] ==
            'cn',
    'proof is scoped to the same claim account and device',
  );
  check(
    !verifiedStore.data.toString().contains('synthetic-human-proof'),
    'verification proof never persists in account storage',
  );
  verified.dispose();

  final cancelledHttp = FakeZcode()
    ..claimCode = 3007
    ..claimHttp = 400;
  final cancelled = await account(
    MemoryAccountStore('cancelled-verification'),
    cancelledHttp,
  );
  final cancelledId = (await cancelled.accounts()).single.id;
  await cancelled.claim(cancelledId, verify: (_) async => null);
  await cancelled.tick();
  check(
    cancelledHttp.claims == 1 &&
        (await cancelled.accounts()).single.status == 'verificationRequired',
    'cancelled challenge and automatic timer cannot resubmit the claim',
  );
  cancelled.dispose();

  final uncertainHttp = FakeZcode()
    ..claimCode = 3007
    ..claimHttp = 400
    ..acceptVerification = true;
  final uncertainOwner = await account(
    MemoryAccountStore('verified-uncertain'),
    uncertainHttp,
  );
  final uncertainId = (await uncertainOwner.accounts()).single.id;
  var uncertainPrompts = 0;
  await uncertainOwner.claim(
    uncertainId,
    verify: (_) async {
      uncertainPrompts++;
      uncertainHttp.loseReply = true;
      uncertainHttp.revealReceipt = false;
      return 'single-use-proof';
    },
  );
  await uncertainOwner.claim(
    uncertainId,
    verify: (_) async {
      uncertainPrompts++;
      return 'must-not-request-another-proof';
    },
  );
  await uncertainOwner.tick();
  check(
    uncertainHttp.claims == 2 &&
        uncertainPrompts == 1 &&
        (await uncertainOwner.accounts()).single.status == 'pending',
    'lost verified POST remains read-only across manual and automatic checks',
  );
  uncertainOwner.dispose();

  final repeatedHttp = FakeZcode()
    ..claimCode = 3007
    ..claimHttp = 400;
  final repeated = await account(
    MemoryAccountStore('repeated-captcha'),
    repeatedHttp,
  );
  var repeatedPrompts = 0;
  await repeated.claim(
    (await repeated.accounts()).single.id,
    verify: (_) async {
      repeatedPrompts++;
      return 'rejected-human-proof';
    },
  );
  check(
    repeatedHttp.claims == 2 &&
        repeatedPrompts == 1 &&
        (await repeated.accounts()).single.status == 'verificationRequired',
    'a second captcha rejection does not loop or reuse a proof',
  );
  repeated.dispose();

  for (final configs in [
    null,
    1,
    {
      'captcha': {'enabled': false},
    },
  ]) {
    var rejectedConfig = false;
    try {
      ZcodeCaptchaConfig.parse(envelope({'configs': configs}));
    } on ZcodeFailure {
      rejectedConfig = true;
    }
    check(
      rejectedConfig,
      'invalid captcha configuration fails without opening a verifier',
    );
  }

  final expiredHttp = FakeZcode()..claimCode = 401;
  final expiredStore = MemoryAccountStore('expired');
  final expired = await account(expiredStore, expiredHttp);
  final eid = (await expired.accounts()).single.id;
  await expired.claim(eid);
  check(
    (await expired.accounts()).single.status == 'authorization_required',
    'explicit unauthorized response requires login',
  );
  expiredHttp.claimCode = 0;
  await expired.beginAuthorization('bigmodel', context, accountId: eid);
  await expired.pollAuthorizationOnce();
  await expired.claim(eid);
  check(
    expiredHttp.claims == 2 &&
        (await expired.accounts()).single.status == 'claimed',
    'reauthorization recovers a definitively rejected claim',
  );
  expired.dispose();

  final regionalStore = MemoryAccountStore('regional');
  final cn = await account(regionalStore, FakeZcode());
  cn.dispose();
  final global = await account(
    regionalStore,
    FakeZcode(),
    family: 'zai',
    deviceContext: {
      ...context,
      'deviceMid': '99999999-2222-4333-8444-555555555555',
    },
  );
  final regional = await global.accounts();
  check(
    regional.length == 2 && regional[0].id != regional[1].id,
    'same UID from separate providers remains isolated',
  );
  global.dispose();

  final stringHttp = FakeZcode()..stringTimes = true;
  final recurring = await account(MemoryAccountStore('recurring'), stringHttp);
  final rid = (await recurring.accounts()).single.id;
  await recurring.claim(rid);
  stringHttp.serverTime += 86400;
  await recurring.claim(rid);
  check(
    stringHttp.claims == 2,
    'numeric-string expiry must permit the next server-offered period',
  );
  recurring.dispose();

  final rejectedHttp = FakeZcode()
    ..claimCode = 3004
    ..claimHttp = 400;
  final rejectedStore = MemoryAccountStore('safe-diagnostics');
  final rejected = await account(rejectedStore, rejectedHttp);
  final rejectedId = (await rejected.accounts()).single.id;
  await rejected.claim(rejectedId);
  final journal = rejectedStore.data['accounts'][rejectedId]['claims']['night'];
  check(
    journal['httpStatus'] == 400 && journal['serviceCode'] == 3004,
    'keep numeric rejection evidence without raw response or credentials',
  );
  await rejected.claim(rejectedId);
  check(rejectedHttp.claims == 1, 'unknown rejection remains read-only');
  rejected.dispose();

  final buckets = ZcodeBalance.parse(
    envelope({
      'server_time': 1793900000,
      'plans': [plan('active')],
      'balances': [
        {
          'bucket_id': 'a',
          'user_plan_id': 'active',
          'unit_type': 'token',
          'remaining_units': '123.5',
          'expires_at': 1793901000,
          'total_units': 999,
        },
        {
          'bucket_id': 'b',
          'user_plan_id': 'active',
          'unit_type': 'requests',
          'remaining_units': 7,
          'expires_at': 1793902000,
        },
      ],
    }),
    now,
  );
  check(
    buckets.buckets[0].remaining == 123.5 &&
        buckets.buckets[0].expiresAt == 1793901000,
    'exact remaining and seconds retained',
  );
  check(buckets.buckets[1].unit == 'requests', 'never mix different units');
  check(
    zcodeMarketingOffers(
      envelope({
        'deliveries': [
          {
            'resource_position': 'popup',
            'popup': {
              'buttons': [
                {
                  'action': {
                    'type': 'open_url',
                    'args': {'plan_id': 'evil'},
                  },
                },
              ],
            },
          },
        ],
      }),
    ).isEmpty,
    'only explicit claim actions become offers',
  );
  print('ZCode activity checks passed');
}
