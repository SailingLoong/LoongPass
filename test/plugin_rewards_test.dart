import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/plugin_accounts.dart';
import '../lib/plugin_rewards.dart';
import '../lib/plugin_runtime.dart';
import '../lib/plugin_zcode_rewards.dart';
import '../lib/zcode_api.dart';
import 'memory_account_store.dart';

class _Harness {
  _Harness(this.directory, this.runtime, this.accounts, this.store);
  final Directory directory;
  final PluginRuntime runtime;
  final PluginAccounts accounts;
  final MemoryAccountStore store;
  late PluginRewards rewards;
  DateTime now = DateTime.utc(2026, 11, 8, 1);
  String get key => accounts.accounts.single.key;
  String identity([String? slot]) {
    final row = store.data['accounts'][slot ?? key];
    return pluginRewardIdentity(row['provider'], row['realm'], row['uid']);
  }

  Map get reward =>
      store.data['rewards']?[identity()] ??
      store.data['accounts'][key]['reward'] ??
      {};
  Future<String> addSlot(String slot, {String uid = 'official'}) async {
    final provider = (store.data['accounts'] as Map).values.first['provider'];
    final next = '$provider#$slot';
    await runtime.call('import', {
      'provider': provider,
      'key': next,
      'auth': {
        'type': 'oauth',
        'uid': uid,
        'accountId': uid,
        'access': 'fake',
        'refresh': '',
        'expires': 0,
      },
    });
    await accounts.refresh();
    return next;
  }

  List<Map> get hooks => File('${directory.path}/hooks.jsonl').existsSync()
      ? File('${directory.path}/hooks.jsonl')
            .readAsLinesSync()
            .map((s) => jsonDecode(s) as Map)
            .toList()
      : [];
  List<Map> get reads => File('${directory.path}/reads.jsonl').existsSync()
      ? File('${directory.path}/reads.jsonl')
            .readAsLinesSync()
            .map((s) => jsonDecode(s) as Map)
            .toList()
      : [];
  Future<void> control(Map<String, dynamic> value) =>
      File('${directory.path}/control.json').writeAsString(jsonEncode(value));
  Future<void> legacy(Map<String, dynamic> value) => accounts.edit((data) {
    data['accounts'][key]['legacy'] = value;
    (data['accounts'][key] as Map).remove('reward');
    (data['rewards'] as Map?)?.remove(identity());
  });
  Future<void> waitForHook() async {
    for (var i = 0; i < 200 && hooks.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(hooks, isNotEmpty);
  }

  Future<void> waitForRead() async {
    for (var i = 0; i < 200 && reads.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(reads, isNotEmpty);
  }

  Future<void> release() =>
      File('${directory.path}/release').writeAsString('yes');
  Future<void> close() async {
    await release();
    await rewards.close();
    await accounts.close();
    await runtime.close();
    await directory.delete(recursive: true);
  }

  static Future<_Harness> open({
    String uid = 'official',
    bool checkin = true,
    bool checkinStatus = true,
    String provider = 'fixture',
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'loongpass-rewards-',
    );
    final plugin = File('${directory.path}/plugin.mjs');
    await plugin.writeAsString('''
      import { appendFileSync, existsSync, readFileSync } from 'node:fs';
      globalThis.fetch = async () => { throw new Error('No network in reward tests'); };
      export const Rewards = async (_, options) => ({
        config: async cfg => { cfg.provider = { [options.provider]: {name: 'Synthetic', api: 'https://fixture.invalid/v1', models: {synthetic: {name: 'Synthetic'}}}}; },
        auth: {
          provider: options.provider, methods: [],
          loader: async () => ({baseURL: 'https://fixture.invalid/v1', apiKey: 'fake'}),
          usage: async () => ({windows: [{name: 'Credits', amount: 99999.125, limit: 100000, unit: 'credits'}]}),
          checkinStatus: options.checkinStatus ? async () => {
            const control = JSON.parse(readFileSync('control.json', 'utf8'));
            const facts = JSON.parse(readFileSync('facts.json', 'utf8'));
            appendFileSync('reads.jsonl', JSON.stringify(Object.values(facts.rewards ?? {})[0] ?? {}) + '\\n');
            while (control.holdRead && !existsSync('release')) await Bun.sleep(5);
            if (control.failRead) throw new Error('private-token-do-not-save');
            return control.status ?? {outcome: 'claimable'};
          } : undefined,
          checkin: options.checkin ? async (_getAuth, _provider, context) => {
            const control = JSON.parse(readFileSync('control.json', 'utf8'));
            const facts = JSON.parse(readFileSync('facts.json', 'utf8'));
            appendFileSync('hooks.jsonl', JSON.stringify({...Object.values(facts.rewards ?? {})[0], dispatchScope: context?.expectedScope}) + '\\n');
            while (control.hold && !existsSync('release')) await Bun.sleep(5);
            if (control.fail) throw new Error('transport failed with private-token-do-not-save');
            return control.reply ?? {outcome: 'claimed', credit: 12.5, streak: 3, message: 'Synthetic receipt'};
          } : undefined,
        },
      });
    ''');
    final runtime = await PluginRuntime.start(
      executable: Platform.environment['LOONGPASS_BUN'] ?? 'bun',
      hostPath: File(
        '${Platform.environment['LOONGPASS_CHECKIN_RUNTIME'] ?? 'runtime'}/vendor/magpie/host.js',
      ).absolute.path,
      launcherPath: File('runtime/launcher.mjs').absolute.path,
      directory: directory.path,
      plugins: [
        {
          'spec': 'synthetic',
          'target': plugin.path,
          'options': {
            'provider': provider,
            'checkin': checkin,
            'checkinStatus': checkinStatus,
          },
        },
      ],
    );
    final store = MemoryAccountStore(directory.path);
    store.afterWrite = () =>
        File('${directory.path}/facts.json')
            .writeAsString(jsonEncode(store.data));
    final accounts = PluginAccounts(
      runtime: runtime,
      directory: directory.path,
      store: store,
      enabledProviders: {provider},
    );
    await runtime.call('import', {
      'provider': provider,
      'key': '$provider#a',
      'auth': {
        'type': 'oauth',
        'uid': uid,
        'accountId': uid,
        'access': 'fake',
        'refresh': provider == 'zcode' ? jsonEncode({'site': 'bigmodel'}) : '',
        'expires': 0,
      },
    });
    await accounts.start();
    final harness = _Harness(directory, runtime, accounts, store);
    harness.rewards = PluginRewards(
      accounts,
      now: () => harness.now,
      timers: false,
    );
    await harness.control({});
    return harness;
  }
}

class _Zcode extends PluginZcodeRewards {
  _Zcode(super.accounts);
  var claims = 0, refreshes = 0;
  bool? automatic;
  @override
  Future<void> claim(
    String key, {
    Future<String?> Function(ZcodeCaptchaConfig)? verify,
    bool automatic = false,
  }) async {
    claims++;
    this.automatic = automatic;
  }

  @override
  Future<void> refresh(String key) async {
    refreshes++;
  }
}

void main() {
  final opened = <_Harness>[];
  Future<_Harness> open({
    String uid = 'official',
    bool checkin = true,
    bool checkinStatus = true,
    String provider = 'fixture',
  }) async {
    final h = await _Harness.open(
      uid: uid,
      checkin: checkin,
      checkinStatus: checkinStatus,
      provider: provider,
    );
    opened.add(h);
    return h;
  }

  tearDown(() async {
    for (final h in opened.reversed) {
      await h.close();
    }
    opened.clear();
  });

  test('status failure creates no claim intent and a later successful read may claim', () async {
    final h = await open();
    await h.control({'failRead': true});
    await h.rewards.claim(h.key);
    expect(h.hooks, isEmpty);
    expect(h.reward['status'], 'unavailable');
    expect(h.reward['attemptId'], isNull);
    expect(
      jsonEncode(h.store.data),
      isNot(contains('private-token-do-not-save')),
    );
    await h.control({});
    await h.rewards.claim(h.key);
    expect(h.hooks, hasLength(1));
    expect(h.reward['status'], 'claimed');
  });

  test('readonly refresh records official done without invoking a claim or inventing a grant', () async {
    final h = await open();
    await h.control({
      'status': {'outcome': 'done', 'scope': 'official-day-a'},
    });
    await h.rewards.refresh(h.key);
    expect(h.hooks, isEmpty);
    expect(h.reward['status'], 'done');
    expect(h.reward['scope'], 'official-day-a');
    expect(h.reward.containsKey('attemptId'), false);
    expect(h.reward.containsKey('credit'), false);
  });

  for (final amount in [null, 0, 12.5]) {
    test(
      'claim receipt retains ${amount ?? 'unknown'} native credits without inventing zero',
      () async {
        final h = await open();
        await h.control({
          'reply': {'outcome': 'claimed', if (amount != null) 'credit': amount},
        });
        await h.rewards.claim(h.key);
        expect(h.reward['status'], 'claimed');
        expect(h.reward['credit'], amount);
        expect(h.reward.containsKey('credit'), amount != null);
        expect(h.reward['unit'], amount != null ? 'credits' : null);
      },
    );
  }

  test(
    'unsupported readonly status still permits the initial Loomy daily claim',
    () async {
      final h = await open(provider: 'loomy', checkinStatus: false);
      await h.rewards.refresh(h.key);
      expect(h.hooks, isEmpty);
      await h.control({'fail': true});
      await h.rewards.claim(h.key);
      expect(h.hooks, hasLength(1));
      h.now = h.now.add(const Duration(days: 3));
      await h.rewards.claim(h.key);
      expect(h.hooks, hasLength(1));
      expect(h.reward['status'], 'pending');
    },
  );

  test('same official scope reconciles a lost reply without resubmitting the claim', () async {
    final h = await open();
    await h.control({
      'status': {'outcome': 'claimable', 'scope': 'official-cycle-a'},
      'fail': true,
    });
    await h.rewards.claim(h.key);
    expect(h.reward['status'], 'pending');
    expect(h.reward['scope'], 'official-cycle-a');
    expect(h.hooks.single['dispatchScope'], 'official-cycle-a');
    await h.control({
      'status': {
        'outcome': 'done',
        'scope': 'official-cycle-a',
        'credit': 12.5,
        'until': '2026-11-09T02:00:00Z',
      },
    });
    await h.rewards.refresh(h.key);
    expect(h.reward['status'], 'done');
    expect(h.reward['credit'], 12.5);
    expect(h.reward['until'], '2026-11-09T02:00:00.000Z');
    expect(h.hooks, hasLength(1));
    await h.rewards.claim(h.key);
    expect(h.hooks, hasLength(1));
  });

  for (final mismatch in ['scope', 'uid', 'realm', 'missing scope']) {
    test(
      'official done cannot reconcile a pending record with mismatched $mismatch',
      () async {
        final h = await open();
        await h.control({
          'status': {'outcome': 'claimable', 'scope': 'cycle-a'},
          'fail': true,
        });
        await h.rewards.claim(h.key);
        await h.accounts.edit((data) {
          final reward = data['rewards'][h.identity()] as Map;
          if (mismatch == 'missing scope') {
            reward.remove('scope');
          } else {
            reward[mismatch] = 'other';
          }
        });
        await h.control({
          'status': {'outcome': 'done', 'scope': 'cycle-a', 'credit': 12.5},
        });
        await h.rewards.refresh(h.key);
        h.now = h.now.add(const Duration(days: 2));
        await h.rewards.claim(h.key);
        expect(h.reward['status'], 'pending');
        expect(h.hooks, hasLength(1));
      },
    );
  }

  test(
    'readonly claimable and unknown answers never clear an uncertain write',
    () async {
      final h = await open();
      await h.control({
        'status': {'outcome': 'claimable', 'scope': 'cycle-a'},
        'fail': true,
      });
      await h.rewards.claim(h.key);
      for (final outcome in [
        'claimable',
        'unknown',
        'inactive',
        'ineligible',
        'captcha',
      ]) {
        await h.control({
          'status': {'outcome': outcome, 'scope': 'cycle-a'},
        });
        await h.rewards.refresh(h.key);
        expect(h.reward['status'], 'pending');
      }
      expect(h.hooks, hasLength(1));
    },
  );

  test(
    'opt-out during preflight stops before a durable intent or a claim',
    () async {
      final h = await open();
      await h.control({'holdRead': true});
      final claim = h.rewards.claim(h.key, automatic: true);
      await h.waitForRead();
      expect(h.reads.single['status'], isNot('pending'));
      await h.accounts.setAutomatic(h.key, false);
      final rejected = expectLater(claim, throwsStateError);
      await h.release();
      await rejected;
      expect(h.hooks, isEmpty);
      expect(h.reward['status'], isNot('pending'));
    },
  );

  test('startup returns before network work and close drains an accepted operation', () async {
    final h = await open();
    await h.control({'hold': true});
    await h.rewards.start().timeout(const Duration(seconds: 1));
    await h.waitForHook();
    var closed = false;
    final close = h.rewards.close().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(closed, false);
    await h.release();
    await close;
    expect(h.reward['status'], 'claimed');
  });

  test('durable pending precedes native hook and exact native credits are retained', () async {
    final h = await open();
    await h.control({
      'reply': {
        'outcome': 'claimed',
        'credit': 12.5,
        'streak': 3,
        'message': 'Synthetic receipt',
        'until': '2026-11-08T18:00:00.000Z',
      },
    });
    await h.rewards.claim(h.key);
    expect(h.hooks, hasLength(1));
    expect(h.hooks.single['status'], 'pending');
    expect(h.hooks.single['attemptId'], isNotEmpty);
    expect(h.reward['status'], 'claimed');
    expect(
      h.reward['credit'],
      12.5,
    ); // 25 half-credits = exactly 12.5 native credits.
    expect(h.reward['unit'], 'credits');
    expect(h.reward['streak'], 3);
    expect(h.reward['message'], 'Synthetic receipt');
    expect(h.reward['until'], '2026-11-08T18:00:00.000Z');
    expect(h.reward.containsKey('confirmedAt'), false);
    expect(h.reward.containsKey('awardedAt'), false);
    await h.rewards.claim(h.key);
    expect(h.hooks, hasLength(1));
    h.now = DateTime.utc(2026, 11, 8, 16);
    await h.rewards.claim(h.key);
    // The native boundary is 18:00 UTC, not midnight in Beijing.
    expect(h.hooks, hasLength(1));
  });

  test(
    'lost native reply remains pending across refresh, restart and later days',
    () async {
      final h = await open();
      await h.control({'fail': true});
      await h.rewards.claim(h.key);
      expect(h.reward['status'], 'pending');
      expect(
        jsonEncode(h.store.data),
        isNot(contains('private-token-do-not-save')),
      );
      await h.rewards.refresh(h.key);
      expect(h.reward['status'], 'pending');
      await h.rewards.close();
      h.now = h.now.add(const Duration(days: 2));
      h.rewards = PluginRewards(h.accounts, now: () => h.now, timers: false);
      await h.rewards.start();
      await h.rewards.claim(h.key);
      expect(h.hooks, hasLength(1));
    },
  );

  test(
    'native failed outcome never schedules a second uncertain call',
    () async {
      final h = await open();
      await h.control({
        'reply': {
          'outcome': 'failed',
          'credit': 0,
          'message': 'unknown',
          'until': '2026-11-08T02:00:00.000Z',
        },
      });
      await h.rewards.claim(h.key);
      h.now = DateTime.utc(2026, 11, 10);
      await h.rewards.claim(h.key);
      expect(h.reward['status'], 'pending');
      expect(h.reward['outcome'], 'failed');
      expect(h.hooks, hasLength(1));
    },
  );

  test('failure to save intent prevents the hook; lost result persistence leaves pending', () async {
    final h = await open();
    h.store.beforeWrite = () async {
      throw StateError('disk unavailable');
    };
    await expectLater(h.rewards.claim(h.key), throwsStateError);
    expect(h.hooks, isEmpty);
    h.store.beforeWrite = null;
    await h.control({'hold': true});
    final claim = h.rewards.claim(h.key);
    await h.waitForHook();
    h.store.beforeWrite = () async {
      throw StateError('disk unavailable');
    };
    final rejected = expectLater(claim, throwsStateError);
    await h.release();
    await rejected;
    expect(h.reward['status'], 'pending');
    h.store.beforeWrite = null;
    await h.rewards.claim(h.key);
    expect(h.hooks, hasLength(1));
  });

  test('uncertain intent acknowledgement cannot be retried from a stale in-memory snapshot', () async {
    final h = await open();
    h.store.afterWrite = () async {
      throw StateError('commit acknowledgement lost');
    };
    await expectLater(h.rewards.claim(h.key), throwsStateError);
    expect(h.reward['status'], 'pending');
    h.store.afterWrite = () =>
        File('${h.directory.path}/facts.json')
            .writeAsString(jsonEncode(h.store.data));
    await h.rewards.claim(h.key);
    expect(h.hooks, isEmpty);
  });

  test('same-account calls serialize and archive a known cycle before the next Beijing day', () async {
    final h = await open();
    await Future.wait([h.rewards.claim(h.key), h.rewards.claim(h.key)]);
    expect(h.hooks, hasLength(1));
    expect(h.reward['until'], '2026-11-08T16:00:00.000Z');
    h.now = DateTime.utc(2026, 11, 8, 16);
    await h.rewards.claim(h.key);
    expect(h.hooks, hasLength(2));
    expect((h.reward['history'] as List).single['credit'], 12.5);
    expect((h.reward['history'] as List).single['status'], 'claimed');
  });

  test(
    'automatic opt-out is honored and explicit manual claim stays available',
    () async {
      final h = await open();
      await h.accounts.setAutomatic(h.key, false);
      await h.rewards.start();
      await h.rewards.claim(h.key, automatic: true);
      expect(h.hooks, isEmpty);
      await h.rewards.claim(h.key);
      expect(h.hooks, hasLength(1));
    },
  );

  test('account opt-in starts work through the data-layer listener', () async {
    final h = await open();
    await h.accounts.setAutomatic(h.key, false);
    await h.rewards.start();
    expect(h.hooks, isEmpty);
    await h.accounts.setAutomatic(h.key, true);
    await h.waitForHook();
    await h.rewards.claim(
      h.key,
    ); // Joins the per-account queue until publication.
    expect(h.reward['status'], 'claimed');
    expect(h.hooks, hasLength(1));
  });

  test(
    'an incomplete persisted receipt cannot authorize another claim',
    () async {
      final h = await open();
      await h.accounts.edit((data) {
        data['accounts'][h.key]['reward'] = {
          'status': 'claimed',
          'credit': 12.5,
          'history': <dynamic>[],
        };
      });
      await expectLater(h.rewards.claim(h.key), throwsStateError);
      expect(h.hooks, isEmpty);
    },
  );

  for (final field in [
    'registrationId',
    'uid',
    'realm',
    'automatic',
    'removed',
  ]) {
    test(
      'a changed $field snapshot cannot publish a late native result',
      () async {
        final h = await open();
        await h.control({'hold': true});
        final claim = h.rewards.claim(h.key, automatic: true);
        final key = h.key;
        final identity = h.identity(key);
        await h.waitForHook();
        await h.accounts.edit((data) {
          data['accounts'][key][field] = field == 'automatic'
              ? false
              : field == 'removed'
              ? true
              : 'changed';
        });
        final rejected = expectLater(claim, throwsStateError);
        await h.release();
        await rejected;
        expect(h.store.data['rewards'][identity]['status'], 'pending');
      },
    );
  }

  test(
    'migrated unresolved records from every old schema prevent native dispatch',
    () async {
      final h = await open();
      final records = [
        {
          'operation': {
            'state': 'unknown',
            'day': '2026-11-01',
            'points': 12.5,
          },
        },
        {
          'operation': {'state': 'claimed', 'day': '2026-11-08'},
          'unresolvedOperations': [
            {'state': 'pending', 'day': '2026-11-01'},
          ],
        },
        {
          'claims': {
            '["official","campaign"]': {
              'state': 'pending',
              'target': {'endAt': 1},
            },
          },
        },
        {
          'journal': {
            'latest': {
              'settled': 'unconfirmed',
              'receipt': 'claimed',
              'day': '2026-11-01',
            },
            'successful': {'settled': 'claimed', 'day': '2026-10-31'},
          },
        },
        {
          'claims': {
            '2026-11-01': {'outcome': 'unknown', 'baseline': 100},
          },
        },
        {
          'journals': {
            '2026-11-01': {'state': 'intent'},
            '2026-11-08': {'state': 'claimed', 'amount': 5000},
          },
        },
      ];
      for (final legacy in records) {
        await h.legacy(legacy);
        await h.rewards.claim(h.key);
        expect(h.reward['status'], 'pending');
        expect(h.reward['legacyPaths'], isNotEmpty);
        expect(h.reward['legacyEvidence'], legacy);
        expect(h.store.data['accounts'][h.key]['reward'], isNull);
      }
      expect(h.hooks, isEmpty);
    },
  );

  test('a known migrated daily receipt blocks the same day and retains its exact amount', () async {
    final h = await open();
    await h.legacy({
      'operation': {'state': 'claimed', 'day': '2026-11-08', 'points': 12.5},
    });
    await h.rewards.claim(h.key);
    expect(h.hooks, isEmpty);
    expect(h.reward['credit'], 12.5);
    expect(h.reward['day'], '2026-11-08');
    h.now = DateTime.utc(2026, 11, 8, 16);
    await h.rewards.claim(h.key);
    expect(h.hooks, hasLength(1));
    expect((h.reward['history'] as List).single['credit'], 12.5);
  });

  test('unknown official identity or a missing advertised native hook cannot claim', () async {
    for (final h in [await open(uid: ''), await open(checkin: false)]) {
      await expectLater(h.rewards.claim(h.key), throwsStateError);
      expect(h.hooks, isEmpty);
    }
  });

  for (final known in [false, true]) {
    test(
      'removed random slot preserves ${known ? 'receipt' : 'unknown'} on re-add',
      () async {
        final h = await open();
        final old = h.key;
        final original = Map<String, dynamic>.from(
          h.store.data['accounts'][old],
        );
        await h.accounts.remove(old);
        await h.accounts.edit((data) {
          data['accounts']['fixture#random-legacy-slot'] = {
            ...original,
            'removed': true,
            'legacy': {
              'operation': {
                'state': known ? 'claimed' : 'unknown',
                'day': '2026-11-08',
                'points': 12.5,
              },
            },
          };
        });
        final next = await h.addSlot('replacement');
        await h.rewards.claim(next);
        expect(h.hooks, isEmpty);
        expect(h.reward['status'], known ? 'claimed' : 'pending');
        if (known) expect(h.reward['credit'], 12.5);
        expect(
          h.accounts.accounts.single.facts['reward']['status'],
          h.reward['status'],
        );
        expect(
          h.store.data['accounts']['fixture#random-legacy-slot']['reward'],
          isNull,
        );
        expect(
          h.store.data['accounts']['fixture#random-legacy-slot']['legacy'],
          isEmpty,
        );
        h.now = h.now.add(const Duration(days: 2));
        await h.rewards.claim(next);
        expect(h.hooks, hasLength(known ? 1 : 0));
        if (known) expect((h.reward['history'] as List).single['credit'], 12.5);
      },
    );
  }

  for (final known in [false, true]) {
    test(
      'canonical ${known ? 'receipt' : 'unknown'} survives native removal and new registration',
      () async {
        final h = await open();
        final first = h.key;
        final identity = h.identity(first);
        await h.control({'fail': !known});
        await h.rewards.claim(first);
        expect(h.hooks, hasLength(1));
        final originalAttempt = h.reward['attemptId'];
        await h.accounts.remove(first);
        final next = await h.addSlot('reauthorized');
        await h.control({});
        await h.rewards.claim(next);
        expect(h.hooks, hasLength(1));
        expect(h.reward['attemptId'], originalAttempt);
        expect(h.reward['status'], known ? 'claimed' : 'pending');
        expect((h.store.data['rewards'] as Map).keys, [identity]);
        final other = await h.addSlot('other-user', uid: 'other-official');
        await h.rewards.claim(other);
        expect(h.hooks, hasLength(2));
        expect(
          h.store.data['rewards'][identity]['status'],
          known ? 'claimed' : 'pending',
        );
        expect(h.store.data['rewards'][h.identity(other)]['status'], 'claimed');
      },
    );
  }

  test(
    'native slots for one official identity serialize across reward owners',
    () async {
      final h = await open();
      final first = h.key;
      final second = await h.addSlot('parallel');
      final owner = PluginRewards(h.accounts, now: () => h.now, timers: false);
      try {
        await Future.wait([h.rewards.claim(first), owner.claim(second)]);
        expect(h.hooks, hasLength(1));
        expect((h.store.data['rewards'] as Map), hasLength(1));
        for (final row in (h.store.data['accounts'] as Map).values) {
          expect(row['reward'], isNull);
        }
        final projection = h.accounts.accounts.first.facts['reward'];
        projection['status'] = 'changed snapshot';
        expect(h.store.data['rewards'][h.identity(first)]['status'], 'claimed');
      } finally {
        await owner.close();
      }
    },
  );

  test(
    'other UID, realm and provider evidence cannot block this identity',
    () async {
      final h = await open();
      final row = Map<String, dynamic>.from(h.store.data['accounts'][h.key]);
      await h.accounts.edit((data) {
        for (final field in ['uid', 'realm', 'provider']) {
          data['accounts']['old-$field'] = {
            ...row,
            field: 'different',
            'removed': true,
            'reward': {
              'status': 'pending',
              'attemptId': 'unknown-$field',
              'history': [],
            },
          };
        }
      });
      await h.rewards.claim(h.key);
      expect(h.hooks, hasLength(1));
      expect(h.reward['status'], 'claimed');
      for (final field in ['uid', 'realm', 'provider']) {
        expect(
          h.store.data['accounts']['old-$field']['reward']['status'],
          'pending',
        );
      }
      expect(
        pluginRewardIdentity('a', 'b', 'c'),
        isNot(pluginRewardIdentity('a', 'c', 'b')),
      );
    },
  );

  test(
    'migration keeps every unknown and known receipt across all slots',
    () async {
      final h = await open();
      final row = Map<String, dynamic>.from(h.store.data['accounts'][h.key]);
      await h.accounts.edit((data) {
        for (var i = 0; i < 2; i++) {
          data['accounts']['old-$i'] = {
            ...row,
            'removed': true,
            'reward': {
              'status': 'pending',
              'attemptId': 'unknown-$i',
              'scope': 'cycle-a',
              'uid': row['uid'],
              'realm': row['realm'],
              'history': [
                {
                  'status': 'claimed',
                  'credit': 12.5 + i,
                  'until': '2026-11-08T16:00:00Z',
                },
              ],
            },
          };
        }
      });
      await h.control({
        'status': {'outcome': 'done', 'scope': 'cycle-a'},
      });
      await h.rewards.claim(h.key);
      final encoded = jsonEncode(h.reward);
      for (final id in ['unknown-0', 'unknown-1'])
        expect(encoded, contains(id));
      for (final credit in [12.5, 13.5]) {
        expect(
          (h.reward['history'] as List).where((e) => e['credit'] == credit),
          hasLength(1),
        );
      }
      expect(h.reward['status'], 'pending');
      expect(h.hooks, isEmpty);
    },
  );

  test(
    'lost migration acknowledgement keeps removed-slot unknown durable',
    () async {
      final h = await open();
      final row = Map<String, dynamic>.from(h.store.data['accounts'][h.key]);
      await h.accounts.edit((data) {
        data['accounts']['old-random'] = {
          ...row,
          'removed': true,
          'reward': {
            'status': 'pending',
            'attemptId': 'lost-ack',
            'history': [],
          },
        };
      });
      h.store.afterWrite = () async {
        throw StateError('commit acknowledgement lost');
      };
      await expectLater(h.rewards.claim(h.key), throwsStateError);
      expect(h.reward['attemptId'], 'lost-ack');
      expect(h.store.data['accounts']['old-random']['reward'], isNull);
      h.store.afterWrite = () =>
          File('${h.directory.path}/facts.json')
              .writeAsString(jsonEncode(h.store.data));
      await h.rewards.claim(h.key);
      expect(h.hooks, isEmpty);
    },
  );

  test('ZCode uses its activity owner and never the native aggregate check-in hook', () async {
    final h = await open(provider: 'zcode');
    final zcode = _Zcode(h.accounts);
    await h.rewards.close();
    h.rewards = PluginRewards(h.accounts, zcode: zcode, timers: false);
    await h.rewards.claim(h.key, automatic: true);
    await h.rewards.refresh(h.key);
    expect(zcode.claims, 1);
    expect(zcode.refreshes, 1);
    expect(zcode.automatic, true);
    expect(h.hooks, isEmpty);
  });
}
