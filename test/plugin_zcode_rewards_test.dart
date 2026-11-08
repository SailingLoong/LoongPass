import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/plugin_accounts.dart';
import '../lib/plugin_runtime.dart';
import '../lib/plugin_zcode_binding.dart';
import '../lib/plugin_zcode_rewards.dart';
import '../lib/zcode_api.dart';
import 'memory_account_store.dart';

const _key = 'zcode#synthetic';
const _teamKey = 'zcode#synthetic-team';
const _time = 1793900000000;
const _oldDevice = '11111111-2222-4333-8444-555555555555';
const _device = '22222222-2222-4333-8444-555555555555';
const _context = <String, String>{
  'version': '3.17.2',
  'platform': 'darwin-arm64',
  'deviceMid': _device,
  'language': 'zh-CN',
  'timezone': 'Asia/Shanghai',
};

Map<String, dynamic> _envelope(Map<String, dynamic> data) => {
  'code': 0,
  'data': data,
};

Map<String, dynamic> _plan(String instance) => {
  'plan_id': 'night',
  'name': 'Start Plan gift',
  'user_plan_id': instance,
  'status': 'active',
  'starts_at': 1793890000,
  'ends_at': 1793903600,
};

/// Only the remote server is synthetic. Native credential reads, account
/// registration, serialized facts writes and the reward transaction are real.
class _Official implements ZcodeTransport {
  final requests = <ZcodeRequest>[];
  final plans = <Map<String, dynamic>>[];
  final buckets = <Map<String, dynamic>>[];
  bool captcha = false, loseReply = false, grant = true;
  int claimHttp = 200, claimCode = 0;
  int? retryAfterMs;
  Future<void> Function(ZcodeRequest)? beforeRequest;
  Future<void> Function()? afterClaim;

  int get posts => requests.where((r) => r.path == ZcodeApi.claimPath).length;

  @override
  Future<ZcodeReply> send(ZcodeRequest r, {bool Function()? isCurrent}) async {
    await beforeRequest?.call(r);
    if (isCurrent?.call() == false) throw const ZcodeFailure('cancelled');
    requests.add(r);
    if (r.path == ZcodeApi.previewPath) {
      return const ZcodeReply(401, {'code': 401}); // Deprecated endpoint.
    }
    if (r.path == ZcodeApi.balancePath) {
      return ZcodeReply(
        200,
        _envelope({
          'server_time': _time ~/ 1000,
          'plans': plans,
          'balances': buckets,
        }),
      );
    }
    if (r.path == ZcodeApi.marketingPath) {
      return ZcodeReply(
        200,
        _envelope({
          'deliveries': [
            {
              'resource_position': 'banner',
              'priority': 1,
              'banner': {
                'content': {
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
            },
          ],
        }),
      );
    }
    if (r.path == ZcodeApi.configPath) {
      return ZcodeReply(
        200,
        _envelope({
          'configs': {
            'captcha': {
              'enabled': captcha,
              'region': 'cn',
              'prefix': 'synthetic',
              'sceneId': 'scene',
            },
          },
        }),
      );
    }
    if (r.path == ZcodeApi.claimPath) {
      if (claimCode != 0 || claimHttp != 200) {
        return ZcodeReply(claimHttp, {
          'code': claimCode,
        }, retryAfterMs: retryAfterMs);
      }
      if (grant) plans.add(_plan('new-instance'));
      await afterClaim?.call();
      if (loseReply) throw const ZcodeFailure('network_unavailable');
      return ZcodeReply(200, _envelope({}));
    }
    throw StateError('Unexpected ZCode endpoint');
  }
}

void main() {
  late Directory directory;
  late PluginRuntime runtime;
  late PluginAccounts accounts;
  late MemoryAccountStore store;
  late _Official official;
  late PluginZcodeRewards rewards;

  Map<String, dynamic> reward() => Map<String, dynamic>.from(
    store.data['zcode']?['rewards']?[jsonEncode(['bigmodel', 'official-a'])] ??
        {},
  );

  Future<void> profile(String key, {String realm = 'bigmodel'}) async {
    await runtime.call('import', {
      'provider': 'zcode',
      'key': key,
      'auth': {
        'type': 'oauth',
        'uid': 'official-a',
        'accountId': '$realm:official-a ($key)',
        'access': 'synthetic-paid-api-key',
        'expires': 0,
        'refresh': jsonEncode({
          'site': realm,
          'jwt': 'synthetic-jwt',
          'key': 'synthetic-paid-api-key',
          'device': _device,
        }),
      },
    });
    await accounts.refresh();
    await accounts.edit((data) {
      data['accounts'][key]['legacy'] = {
        'claims': <String, dynamic>{},
        'bindingHistory': <dynamic>[],
        'buckets': <dynamic>[],
        'context': _context,
      };
    });
  }

  Future<void> legacy(Map<String, dynamic> facts) => accounts.edit((data) {
    data['accounts'][_key]['legacy'] = {
      'claims': <String, dynamic>{},
      'bindingHistory': <dynamic>[],
      'buckets': <dynamic>[],
      'context': _context,
      ...facts,
    };
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'loongpass-zcode-reward-',
    );
    runtime = await PluginRuntime.start(
      executable: Platform.environment['LOONGPASS_BUN'] ?? 'bun',
      hostPath: File('runtime/vendor/magpie/host.js').absolute.path,
      launcherPath: File('runtime/launcher.mjs').absolute.path,
      directory: directory.path,
      plugins: [
        {
          'spec': 'fixture',
          'target': File('test/fixtures/native_plugin.mjs').absolute.path,
          'options': {'provider': 'zcode'},
        },
      ],
    );
    await runtime.call('import', {
      'provider': 'zcode',
      'key': _key,
      'auth': {
        'type': 'oauth',
        'uid': 'official-a',
        'accountId': 'Synthetic',
        'access': 'synthetic-paid-api-key',
        'expires': 0,
        'refresh': jsonEncode({
          'site': 'bigmodel',
          'jwt': 'synthetic-jwt',
          'key': 'synthetic-paid-api-key',
          'device': _device,
        }),
      },
    });
    store = MemoryAccountStore(directory.path);
    accounts = PluginAccounts(
      runtime: runtime,
      directory: directory.path,
      store: store,
      enabledProviders: {'zcode'},
    );
    await accounts.start();
    await legacy({});
    official = _Official();
    rewards = PluginZcodeRewards(
      accounts,
      api: ZcodeApi(official),
      now: () => _time,
    );
  });

  tearDown(() async {
    await rewards.close();
    await accounts.close();
    await runtime.close();
    await directory.delete(recursive: true);
  });

  test('device reservation excludes current and every historical device and never changes auth', () async {
    const first = '33333333-2222-4333-8444-555555555555';
    const second = '44444444-2222-4333-8444-555555555555';
    await legacy({
      'bindingHistory': [
        {
          'context': {..._context, 'deviceMid': _oldDevice},
          'claims': <String, dynamic>{},
        },
      ],
    });
    await accounts.edit((data) {
      data['zcode'] = {
        'devicePool': [_oldDevice, _device, first, second],
      };
    });
    final before = jsonEncode(store.data);
    final authBefore = await accounts.credentials.account(_key);
    final target = accounts.accounts.single;
    final a = await ZcodeDeviceReservation.take(accounts, target);
    final b = await ZcodeDeviceReservation.take(accounts, target);
    ZcodeDeviceReservation? replacement;
    try {
      expect(a.device, first);
      expect(b.device, second);
      await expectLater(
        ZcodeDeviceReservation.take(accounts, target),
        throwsA(
          isA<ZcodeFailure>().having(
            (e) => e.code,
            'code',
            'device_pool_empty',
          ),
        ),
      );
      a.release();
      replacement = await ZcodeDeviceReservation.take(accounts, target);
      expect(replacement.device, first);
      a.release(); // An old lease cannot release its new holder.
      await expectLater(
        ZcodeDeviceReservation.take(accounts, target),
        throwsA(isA<ZcodeFailure>()),
      );
      expect(jsonEncode(store.data), before);
      expect(await accounts.credentials.account(_key), authBefore);
      expect(official.requests, isEmpty);
    } finally {
      a.release();
      b.release();
      replacement?.release();
    }
  });

  test('binding capture archives a verified device change while retaining an unknown transaction', () async {
    await legacy({
      'claims': {
        'night': {
          'state': 'pending',
          'previous': <String>[],
          'submittedAt': _time,
        },
      },
    });
    await rewards.captureBinding(_key);
    expect(reward()['bindingHistory'], isEmpty);
    final auth = await accounts.credentials.account(_key);
    await runtime.call('import', {
      'provider': 'zcode',
      'key': _key,
      'auth': {
        ...auth,
        'refresh': jsonEncode({
          ...jsonDecode(auth['refresh'] as String) as Map,
          'device': _oldDevice,
        }),
      },
    });
    await accounts.authorizationSaved(_key);
    await rewards.captureBinding(_key);
    expect(reward()['context']['deviceMid'], _oldDevice);
    expect(reward()['bindingHistory'][0]['context']['deviceMid'], _device);
    expect(
      reward()['bindingHistory'][0]['claims']['night']['state'],
      'pending',
    );
    expect(official.requests, isEmpty);
    await accounts.edit((data) {
      data['zcode']['devicePool'] = [_oldDevice, _device];
    });
    await expectLater(
      ZcodeDeviceReservation.take(accounts, accounts.accounts.single),
      throwsA(
        isA<ZcodeFailure>().having((e) => e.code, 'code', 'device_pool_empty'),
      ),
    );
  });

  test('lost intent acknowledgement stays authoritative across personal and team profiles', () async {
    await profile(_teamKey);
    store.afterWrite = () async {
      final journal = store.data['accounts'][_key]['reward'] ?? reward();
      if (journal['status'] == 'pending') {
        throw StateError('Synthetic commit acknowledgement lost');
      }
    };
    await expectLater(
      rewards.claim(_key),
      throwsA(
        isA<ZcodeFailure>().having(
          (e) => e.code,
          'code',
          'storage_unavailable',
        ),
      ),
    );
    expect(official.posts, 0);
    store.afterWrite = null;
    await rewards.claim(_key);
    await rewards.claim(_teamKey);
    expect(official.posts, 0);
    expect(reward()['claims']['night']['state'], 'pending');
    for (final account in accounts.accounts) {
      expect(account.facts['reward']['claims']['night']['state'], 'pending');
      expect(store.data['accounts'][account.key].containsKey('reward'), false);
    }
  });

  test(
    'personal and team profiles share one in-flight captcha transaction',
    () async {
      await profile(_teamKey);
      official.captcha = true;
      final started = Completer<void>(), resume = Completer<String?>();
      final first = rewards.claim(
        _key,
        verify: (_) {
          started.complete();
          return resume.future;
        },
      );
      await started.future;
      final other = PluginZcodeRewards(
        accounts,
        api: ZcodeApi(official),
        now: () => _time,
      );
      Object? failure;
      try {
        await other.claim(_teamKey);
      } catch (e) {
        failure = e;
      } finally {
        resume.complete('synthetic-proof');
        await first;
        await other.close();
      }
      expect(
        failure,
        isA<ZcodeFailure>().having((e) => e.code, 'code', 'busy'),
      );
      expect(official.posts, 1);
      expect(reward()['claims']['night']['instance'], 'new-instance');
    },
  );

  test('canonical migration preserves unknown evidence from every profile and binding', () async {
    await profile(_teamKey);
    await accounts.edit((data) {
      data['accounts'][_key]['reward'] = {
        'claims': {
          'night': {
            'state': 'claimed',
            'previous': <String>[],
            'instance': 'expired',
            'endsAt': 1,
          },
        },
        'bindingHistory': <dynamic>[],
        'context': _context,
      };
      data['accounts'][_teamKey]['legacy']['bindingHistory'] = [
        {
          'context': {..._context, 'deviceMid': _oldDevice},
          'changedAt': _time - 10,
          'claims': {
            'night': {
              'state': 'unknown',
              'previous': ['old-instance'],
              'proofMarker': 'must-survive',
            },
          },
        },
      ];
    });
    await rewards.claim(_key);
    expect(official.posts, 0);
    expect(reward()['status'], 'pending');
    expect(jsonEncode(reward()), contains('must-survive'));
    expect(jsonEncode(reward()), contains('expired'));
    expect(accounts.accounts.map((a) => a.facts['reward']).toList(), [
      reward(),
      reward(),
    ]);
    official.plans.add(_plan('new-instance'));
    await rewards.refresh(_teamKey);
    official.plans.clear();
    await rewards.refresh(_key);
    expect(reward()['status'], 'observedClaimed');
    expect(jsonEncode(reward()), contains('must-survive'));
  });

  test('equal official UIDs in different realms retain separate reward transactions', () async {
    const otherKey = 'zcode#synthetic-zai';
    await profile(otherKey, realm: 'zai');
    official.grant = false;
    official.loseReply = true;
    await rewards.claim(_key);
    await rewards.claim(otherKey);
    expect(official.posts, 2);
    expect(store.data['zcode']['rewards'].keys.toSet(), {
      jsonEncode(['bigmodel', 'official-a']),
      jsonEncode(['zai', 'official-a']),
    });
  });

  test(
    'unknown attempt from any old binding blocks the same activity POST',
    () async {
      await legacy({
        'bindingHistory': [
          {
            'context': {..._context, 'deviceMid': _oldDevice},
            'changedAt': _time - 5,
            'claims': {
              'night': {
                'state': 'pending',
                'previous': ['previous-instance'],
                'submittedAt': _time - 10,
                'unrecognizedHistoricalFact': 'preserved',
              },
            },
          },
        ],
      });
      await rewards.claim(_key);
      expect(official.posts, 0);
      expect(reward()['status'], 'pending');
      final old = reward()['bindingHistory'][0]['claims']['night'];
      expect(old['state'], 'pending');
      expect(old['unrecognizedHistoricalFact'], 'preserved');
      expect(reward()['context']['deviceMid'], _device);
    },
  );

  test('nested imported binding history cannot hide an unknown activity', () async {
    await legacy({
      'bindingHistory': [
        {
          'context': _context,
          'claims': <String, dynamic>{},
          'bindingHistory': [
            {
              'context': {..._context, 'deviceMid': _oldDevice},
              'claims': {
                'night': {'state': 'unknown', 'previous': <String>[]},
              },
            },
          ],
        },
      ],
    });
    await rewards.claim(_key);
    expect(official.posts, 0);
    expect(reward()['status'], 'pending');
    official.plans.add(_plan('verified-instance'));
    await rewards.refresh(_key);
    expect(
      reward()['bindingHistory'][0]['bindingHistory'][0]['claims']['night']['instance'],
      'verified-instance',
    );
  });

  test('balance reconciles historical pending by a new official entitlement instance', () async {
    await legacy({
      'context': {..._context, 'deviceMid': _oldDevice},
      'claims': {
        'night': {
          'state': 'pending',
          'previous': ['previous-instance'],
          'submittedAt': _time - 10,
        },
      },
    });
    official.plans.add(_plan('new-instance'));
    await rewards.refresh(_key);
    expect(official.posts, 0);
    final old = reward()['bindingHistory'][0]['claims']['night'];
    expect(old['state'], 'claimed');
    expect(old['instance'], 'new-instance');
    expect(old['previous'], ['previous-instance']);
    expect(old['submittedAt'], _time - 10);
    expect(old['endsAt'], 1793903600);
  });

  test('marketing discovery survives deprecated preview and commits intent before POST', () async {
    official.beforeRequest = (r) async {
      if (r.path == ZcodeApi.claimPath) {
        expect(reward()['claims']['night']['state'], 'pending');
        expect(reward()['claims']['night']['submittedAt'], _time);
        expect(reward()['claims']['night']['previous'], isEmpty);
      }
      expect(r.token, 'synthetic-jwt');
      expect(r.context, _context);
    };
    await rewards.claim(_key);
    expect(official.posts, 1);
    expect(official.requests.any((r) => r.path == ZcodeApi.previewPath), false);
    expect(reward()['claims']['night']['state'], 'claimed');
    expect(reward()['claims']['night']['instance'], 'new-instance');
    await rewards.claim(_key);
    expect(official.posts, 1);
    expect(jsonEncode(store.data), isNot(contains('synthetic-jwt')));
    expect(jsonEncode(store.data), isNot(contains('synthetic-paid-api-key')));
  });

  test('captcha is verified before the sole POST and concurrent dispatch is rejected', () async {
    official.captcha = true;
    final started = Completer<void>(), resume = Completer<String?>();
    final first = rewards.claim(
      _key,
      verify: (config) {
        expect(official.posts, 0);
        expect(reward()['status'], 'verificationRequired');
        expect(config.values['sceneId'], 'scene');
        started.complete();
        return resume.future;
      },
    );
    await started.future;
    await expectLater(rewards.claim(_key), throwsA(isA<ZcodeFailure>()));
    resume.complete('synthetic-proof');
    await first;
    expect(official.posts, 1);
    final posted = official.requests.singleWhere(
      (r) => r.path == ZcodeApi.claimPath,
    );
    expect(
      posted.verification!.headers['X-Aliyun-Captcha-Verify-Param'],
      'synthetic-proof',
    );
    expect(reward()['status'], 'claimed');
  });

  test('cancelled captcha and automatic invocations never dispatch an unverified claim', () async {
    official.captcha = true;
    var prompts = 0;
    await rewards.claim(
      _key,
      verify: (_) async {
        prompts++;
        return null;
      },
    );
    await rewards.claim(_key);
    await rewards.claim(_key);
    expect(prompts, 1);
    expect(official.posts, 0);
    expect(reward()['claims']['night']['state'], 'verificationRequired');
  });

  test(
    'removal or reauthorization during captcha invalidates pending work',
    () async {
      official.captcha = true;
      await expectLater(
        rewards.claim(
          _key,
          verify: (_) async {
            await accounts.edit((data) {
              data['accounts'][_key]['registrationId'] = 'new-authorization';
            });
            return 'stale-proof';
          },
        ),
        throwsA(isA<ZcodeFailure>()),
      );
      expect(official.posts, 0);
      expect(reward()['claims']['night']['state'], 'verificationRequired');
    },
  );

  test(
    'removing an account during balance read prevents late publication',
    () async {
      final started = Completer<void>(), resume = Completer<void>();
      official.beforeRequest = (r) async {
        if (r.path == ZcodeApi.balancePath) {
          started.complete();
          await resume.future;
        }
      };
      final refresh = rewards.refresh(_key);
      await started.future;
      final old = jsonEncode(reward());
      await accounts.edit((data) {
        data['accounts'][_key]['removed'] = true;
      });
      resume.complete();
      await expectLater(refresh, throwsA(isA<ZcodeFailure>()));
      expect(jsonEncode(reward()), old);
      expect(official.posts, 0);
    },
  );

  test(
    'lost POST result stays pending through restart without another dispatch',
    () async {
      official.loseReply = true;
      official.grant = false;
      await rewards.claim(_key);
      expect(reward()['status'], 'pending');
      await rewards.close();
      rewards = PluginZcodeRewards(
        accounts,
        api: ZcodeApi(official),
        now: () => _time,
      );
      await rewards.claim(_key);
      expect(official.posts, 1);
      expect(reward()['claims']['night']['state'], 'pending');
    },
  );

  test(
    'disabling automatic claims during discovery prevents POST and publication',
    () async {
      final started = Completer<void>(), resume = Completer<void>();
      official.beforeRequest = (r) async {
        if (r.path == ZcodeApi.marketingPath) {
          started.complete();
          await resume.future;
        }
      };
      final before = jsonEncode(reward());
      final claim = rewards.claim(_key, automatic: true);
      await started.future;
      await accounts.setAutomatic(_key, false);
      final cancelled = expectLater(
        claim,
        throwsA(isA<ZcodeFailure>().having((e) => e.code, 'code', 'cancelled')),
      );
      resume.complete();
      await cancelled;
      expect(official.posts, 0);
      expect(jsonEncode(reward()), before);
    },
  );

  test(
    'disabling automatic claims during captcha prevents the verified POST',
    () async {
      official.captcha = true;
      await expectLater(
        rewards.claim(
          _key,
          automatic: true,
          verify: (_) async {
            await accounts.setAutomatic(_key, false);
            return 'proof';
          },
        ),
        throwsA(isA<ZcodeFailure>().having((e) => e.code, 'code', 'cancelled')),
      );
      expect(official.posts, 0);
      expect(reward()['claims']['night']['state'], 'verificationRequired');
    },
  );

  test('disabling automatic claims after dispatch preserves pending for reconciliation', () async {
    final started = Completer<void>(), resume = Completer<void>();
    official.afterClaim = () async {
      started.complete();
      await resume.future;
    };
    final claim = rewards.claim(_key, automatic: true);
    await started.future;
    expect(reward()['claims']['night']['state'], 'pending');
    await accounts.setAutomatic(_key, false);
    final cancelled = expectLater(
      claim,
      throwsA(isA<ZcodeFailure>().having((e) => e.code, 'code', 'cancelled')),
    );
    resume.complete();
    await cancelled;
    expect(official.posts, 1);
    expect(reward()['claims']['night']['state'], 'pending');
    await rewards.refresh(_key);
    expect(reward()['claims']['night']['instance'], 'new-instance');
    expect(reward()['claims']['night']['state'], 'claimed');
    expect(official.posts, 1);
  });

  test(
    'manual claims remain available when automatic claims are disabled',
    () async {
      await accounts.setAutomatic(_key, false);
      await rewards.claim(_key);
      expect(official.posts, 1);
      expect(reward()['claims']['night']['state'], 'claimed');
    },
  );

  test('Retry-After is exact for HTTP and body rate limits and blocks every request', () async {
    for (final httpStatus in [429, 200]) {
      var clock = _time;
      await rewards.close();
      await accounts.edit((data) {
        data['zcode']?['rewards']?.remove(
          jsonEncode(['bigmodel', 'official-a']),
        );
        data['accounts'][_key]['legacy'] = {'context': _context};
      });
      rewards = PluginZcodeRewards(
        accounts,
        api: ZcodeApi(official),
        now: () => clock,
      );
      official.claimHttp = httpStatus;
      official.claimCode = 3002;
      official.retryAfterMs = 7000;
      await rewards.claim(_key);
      expect(reward()['rateLimit'], {'waitMs': 7000, 'retryAt': _time + 7000});
      expect(reward()['claims']['night']['state'], 'throttled');
      final calls = official.requests.length;
      clock += 6999;
      await rewards.refresh(_key);
      await rewards.claim(_key);
      expect(official.requests.length, calls);
      clock++;
      await rewards.claim(_key);
      expect(official.requests.length, greaterThan(calls));
      expect(reward()['rateLimit']['retryAt'], _time + 14000);
      clock += 7000;
      official.retryAfterMs = 86400000;
      await rewards.claim(_key);
      expect(reward()['rateLimit'], {
        'waitMs': 21600000,
        'retryAt': clock + 21600000,
      });
    }
  });

  test(
    'missing Retry-After follows native exponential wait and six-hour cap',
    () async {
      var clock = _time;
      await rewards.close();
      rewards = PluginZcodeRewards(
        accounts,
        api: ZcodeApi(official),
        now: () => clock,
      );
      official.claimHttp = 429;
      official.claimCode = 3002;
      for (final expected in [
        1800000,
        3600000,
        7200000,
        14400000,
        21600000,
        21600000,
      ]) {
        await rewards.claim(_key);
        expect(reward()['rateLimit']['waitMs'], expected);
        expect(reward()['rateLimit']['retryAt'], clock + expected);
        clock += expected;
      }
      expect(official.posts, 6);
    },
  );

  test(
    'Retry-After starts when the rejection arrives, not when the POST starts',
    () async {
      var clock = _time;
      await rewards.close();
      rewards = PluginZcodeRewards(
        accounts,
        api: ZcodeApi(official),
        now: () => clock,
      );
      official.claimHttp = 429;
      official.claimCode = 3002;
      official.retryAfterMs = 7000;
      official.beforeRequest = (r) async {
        if (r.path == ZcodeApi.claimPath) clock += 5000;
      };
      await rewards.claim(_key);
      expect(reward()['claims']['night']['submittedAt'], _time);
      expect(reward()['rateLimit']['retryAt'], _time + 12000);
    },
  );

  test('failed durable intent commit prevents POST', () async {
    store.beforeWrite = () async {
      throw StateError('Synthetic disk unavailable');
    };
    await expectLater(
      rewards.claim(_key),
      throwsA(
        isA<ZcodeFailure>().having(
          (e) => e.code,
          'code',
          'storage_unavailable',
        ),
      ),
    );
    expect(official.posts, 0);
    store.beforeWrite = null;
    await rewards.claim(_key);
    expect(official.posts, 1);
    expect(reward()['claims']['night']['instance'], 'new-instance');
  });

  test('official code 1004 is a definite eligibility rejection with retained attempts', () async {
    official.claimHttp = 400;
    official.claimCode = 1004;
    await rewards.claim(_key);
    expect(reward()['status'], 'ineligible');
    expect(reward()['claims']['night']['serviceCode'], 1004);
    official.claimHttp = 200;
    official.claimCode = 0;
    await rewards.claim(_key);
    expect(reward()['claims']['night']['state'], 'claimed');
    final historical = reward()['claims']['night']['attempts'] as List;
    expect(historical.last['state'], 'ineligible');
    expect(historical.last['httpStatus'], 400);
    expect(historical.last['serviceCode'], 1004);
    expect(official.posts, 2);
  });

  test('retained rate-limit evidence is recovered before any request after rebinding', () async {
    await legacy({
      'context': {..._context, 'deviceMid': _oldDevice},
      'claims': {
        'night': {
          'state': 'pending',
          'previous': <String>[],
          'submittedAt': _time - 1000,
          'httpStatus': 429,
          'serviceCode': 3002,
          'retryAfterMs': 7000,
        },
      },
    });
    await rewards.claim(_key);
    expect(official.requests, isEmpty);
    expect(reward()['rateLimit'], {'waitMs': 7000, 'retryAt': _time + 6000});
    expect(
      reward()['bindingHistory'][0]['claims']['night']['state'],
      'throttled',
    );
  });

  test(
    'official entitlement acquired during captcha prevents a duplicate POST',
    () async {
      official.captcha = true;
      await rewards.claim(
        _key,
        verify: (_) async {
          official.plans.add(_plan('official-client-instance'));
          return 'proof';
        },
      );
      expect(official.posts, 0);
      expect(reward()['status'], 'observedClaimed');
      expect(
        reward()['claims']['night']['instance'],
        'official-client-instance',
      );
    },
  );

  test('fresh native account uses supplied client context with native device identity', () async {
    await accounts.edit((data) {
      data['accounts'][_key].remove('legacy');
    });
    await rewards.close();
    rewards = PluginZcodeRewards(
      accounts,
      api: ZcodeApi(official),
      now: () => _time,
      contextFor: (a, auth) async {
        expect(a.uid, 'official-a');
        expect(auth['uid'], 'official-a');
        return {..._context, 'deviceMid': _oldDevice};
      },
    );
    await rewards.refresh(_key);
    expect(reward()['context'], _context);
    expect(
      official.requests.every((r) => r.context['deviceMid'] == _device),
      true,
    );
    expect(official.posts, 0);
  });

  test('native context refreshes request metadata while preserving prior receipt context', () async {
    await legacy({
      'claims': {
        'night': {'state': 'pending', 'previous': <String>[]},
      },
    });
    var version = '3.18.0';
    await rewards.close();
    rewards = PluginZcodeRewards(
      accounts,
      api: ZcodeApi(official),
      now: () => _time,
      contextFor: (_, _) async => {
        ..._context,
        'version': version,
        'deviceMid': _oldDevice,
      },
    );
    await rewards.refresh(_key);
    expect(official.posts, 0);
    expect(reward()['context']['version'], '3.18.0');
    expect(reward()['context']['deviceMid'], _device);
    expect(reward()['bindingHistory'][0]['context'], _context);
    expect(
      reward()['bindingHistory'][0]['claims']['night']['state'],
      'pending',
    );
    official.requests.clear();
    version = '3.18.1';
    await rewards.refresh(_key);
    expect(
      official.requests.every((r) => r.context['version'] == '3.18.1'),
      true,
    );
    expect(reward()['status'], 'pending');
  });

  test(
    'Start Plan keeps exact token units separate from any paid plan assumption',
    () async {
      official.plans.add(_plan('current-gift'));
      official.buckets.add({
        'plan_id': 'night',
        'user_plan_id': 'current-gift',
        'show_name': 'GLM gift',
        'unit_type': 'tokens',
        'remaining_units': '12345678',
        'used_units': '7654322',
        'total_units': '20000000',
        'expires_at': 1793903600,
      });
      await rewards.refresh(_key);
      expect(reward()['buckets'], [
        {
          'label': 'GLM gift',
          'unit': 'tokens',
          'remaining': 12345678.0,
          'expiresAt': 1793903600,
        },
      ]);
      expect(reward()['plans'][0]['user_plan_id'], 'current-gift');
      expect(reward()['checkedAt'], _time);
      expect(reward().containsKey('paidPlan'), false);
      // Hand check: 20,000,000 total - 7,654,322 used = 12,345,678 tokens.
    },
  );
}
