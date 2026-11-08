import 'dart:io';

import '../lib/zcode_activity_accounts.dart';
import '../lib/zcode_api.dart';
import '../lib/zcode_rewards.dart';
import 'memory_account_store.dart';
import 'zcode_activities_checks.dart' as f;

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

void main() async {
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
    'plan-id-only ZCode balances expose exact remaining and entitled model without claiming an instance',
    () async {
      final balance = ZcodeBalance.parse(
        f.envelope({
          'server_time': 1793900000,
          'plans': [
            {
              'plan_id': 'zcode-v3-start-plan-1029',
              'name': 'ZCODE GLOBAL BUILD',
              'status': 'active',
              'starts_at': 1793854560,
              'ends_at': 1793903737,
            },
          ],
          'balances': [
            {
              'plan_id': 'zcode-v3-start-plan-1029',
              'show_name': 'GLM-5.3',
              'capabilities': ['model:GLM-5.3'],
              'total_units': 3000000,
              'used_units': 450000,
              'remaining_units': 2550000,
            },
          ],
        }),
        f.now,
      );
      check(
        balance.buckets.single.remaining == 2550000 &&
            balance.buckets.single.expiresAt == 1793903737,
        'plan-only balance or exact 2550000 remaining units lost',
      );
      check(
        balance.entitledModels.single == 'glm-5.3',
        'model entitlement differs from observed usable balance',
      );
      check(
        balance.receipt('zcode-v3-start-plan-1029', <dynamic>[]) == null,
        'plan-only observation fabricated a new entitlement instance',
      );
    },
  );

  await run(
    'ambiguous ZCode plan fallback cannot confer a model entitlement',
    () async {
      final balance = ZcodeBalance.parse(
        f.envelope({
          'server_time': 1793900000,
          'plans': [f.plan('instance-a'), f.plan('instance-b')],
          'balances': [
            {
              'plan_id': 'night',
              'capabilities': ['model:GLM-5.3'],
              'remaining_units': 2550000,
            },
          ],
        }),
        f.now,
      );
      check(
        balance.buckets.isEmpty,
        'ambiguous plan bucket was displayed as usable',
      );
      check(
        balance.entitledModels.isEmpty,
        'ambiguous plan bucket granted inference',
      );
    },
  );

  await run(
    'ZCode entitlement facts exclude spent, expired and not-started resources',
    () async {
      final balance = ZcodeBalance.parse(
        f.envelope({
          'server_time': 1793900000,
          'plans': [
            f.plan('live'),
            {...f.plan('future'), 'starts_at': 1793900001},
            f.plan('expired', end: 1793899999),
          ],
          'balances': [
            {
              'user_plan_id': 'live',
              'used_units': 5,
              'total_units': 8,
              'capabilities': [' model: GLM-Live ', 'tool:web-search'],
            },
            {
              'user_plan_id': 'live',
              'remaining_units': 0,
              'capabilities': ['model:spent'],
            },
            {
              'user_plan_id': 'future',
              'remaining_units': 20,
              'capabilities': ['model:not-started'],
            },
            {
              'user_plan_id': 'expired',
              'remaining_units': 20,
              'capabilities': ['model:expired-plan'],
            },
            {
              'user_plan_id': 'live',
              'remaining_units': 20,
              'expires_at': 1793899999,
              'capabilities': ['model:expired-bucket'],
            },
            {
              'user_plan_id': 'live',
              'capabilities': ['model:unknown-balance'],
            },
            {'user_plan_id': 'live', 'remaining_units': 20, 'capabilities': []},
            {
              'plan_id': 'night',
              'user_plan_id': 'unobserved-instance',
              'remaining_units': 20,
              'capabilities': ['model:unobserved'],
            },
          ],
        }),
        f.now,
      );
      check(
        balance.entitledModels.single == 'glm-live',
        'unavailable resource granted inference',
      );
      check(
        balance.receipt('night', ['live', 'future', 'expired']) == null,
        'an old instance was treated as a new receipt',
      );
    },
  );

  await run(
    'ZCode throttling is a definite rejection, held across restart, and later eligible',
    () async {
      for (final status in [200, 429]) {
        var now = f.now;
        final http = f.FakeZcode()
          ..claimCode = status == 429 ? 3004 : 3002
          ..claimHttp = status;
        final store = MemoryAccountStore('zcode-throttled-$status');
        final saved = await f.account(store, http);
        final id = (await saved.accounts()).single.id;
        saved.dispose();
        var owner = ZcodeActivityAccounts(
          store: store,
          api: ZcodeApi(http),
          now: () => now,
        );
        try {
          await owner.claim(id);
          check(
            (await owner.accounts()).single.status != 'pending' &&
                http.claims == 1,
            'definite throttling was retained as an uncertain claim',
          );
          await owner.tick();
          check(http.claims == 1, 'rate-limited claim retried immediately');
          owner.dispose();
          owner = ZcodeActivityAccounts(
            store: store,
            api: ZcodeApi(http),
            now: () => now,
          );
          await owner.tick();
          check(http.claims == 1, 'restart bypassed rate-limit hold');
          now += const Duration(minutes: 30).inMilliseconds;
          http.claimCode = 0;
          http.claimHttp = 200;
          await owner.tick();
          check(
            http.claims == 2 &&
                (await owner.accounts()).single.status == 'claimed',
            'definitively rejected claim never became eligible later',
          );
        } finally {
          owner.dispose();
        }
      }
    },
  );
  await run(
    'a plan-only observation during verification never fabricates a claim receipt',
    () async {
      final http = f.FakeZcode()
        ..captchaRequired = true
        ..claimCode = 3007
        ..claimHttp = 400;
      final store = MemoryAccountStore('zcode-observed-without-instance');
      final owner = await f.account(store, http);
      final id = (await owner.accounts()).single.id;
      try {
        await owner.claim(
          id,
          verify: (_) async {
            http.balances['synthetic-bigmodel'] = [
              f.plan('not-an-observed-instance')..remove('user_plan_id'),
            ];
            return 'synthetic-human-proof';
          },
        );
        final account = (await owner.accounts()).single;
        final claim = store.data['accounts'][id]['claims']['night'] as Map;
        check(
          account.status == 'observedClaimed' &&
              account.latestClaim == null &&
              claim['state'] != 'claimed' &&
              claim['instance'] == null,
          'plan-only observation became a confirmed activity instance',
        );
        await owner.claim(id);
        check(http.claims == 0, 'observed active plan was claimed again');
      } finally {
        owner.dispose();
      }
    },
  );
  exitCode = failed == 0 ? 0 : 1;
}
