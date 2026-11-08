import 'dart:io';

import '../lib/zcode_activity_accounts.dart';
import '../lib/zcode_api.dart';
import 'memory_account_store.dart';
import 'zcode_activities_checks.dart' as f;

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

class Official extends f.FakeZcode {
  Object? captcha = {
    'enabled': true,
    'region': 'cn',
    'prefix': 'synthetic',
    'sceneId': 'scene',
  };
  bool unavailable = false;
  @override
  Future<ZcodeReply> send(
    ZcodeRequest request, {
    bool Function()? isCurrent,
  }) async {
    if (request.path == ZcodeApi.configPath) {
      received.add(request);
      if (unavailable) throw const ZcodeFailure('network_unavailable');
      return ZcodeReply(
        200,
        f.envelope({
          'configs': {if (captcha != null) 'captcha': captcha},
        }),
      );
    }
    return super.send(request, isCurrent: isCurrent);
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
    'configured ZCode attestation precedes the first and only verified POST',
    () async {
      for (final omitEnabled in [false, true]) {
        final http = Official();
        if (omitEnabled) (http.captcha as Map).remove('enabled');
        final owner = await f.account(
          MemoryAccountStore('zcode-preflight-$omitEnabled'),
          http,
        );
        final id = (await owner.accounts()).single.id;
        var verifications = 0;
        try {
          await owner.claim(
            id,
            verify: (_) async {
              verifications++;
              check(
                http.claims == 0,
                'unverified claim preceded known-required attestation',
              );
              return 'synthetic-fresh-proof';
            },
          );
          final posted = http.received
              .where((r) => r.path == ZcodeApi.claimPath)
              .toList();
          check(
            verifications == 1 &&
                posted.length == 1 &&
                posted.single.verification != null &&
                (await owner.accounts()).single.status == 'claimed',
            'first claim was not verified exactly once',
          );
        } finally {
          owner.dispose();
        }
      }
    },
  );

  await run(
    'unknown or unavailable ZCode attestation configuration never posts a claim',
    () async {
      for (final kind in ['malformed', 'malformed-enabled', 'unavailable']) {
        final http = Official();
        if (kind == 'malformed')
          http.captcha = 'unknown';
        else if (kind == 'malformed-enabled')
          (http.captcha as Map)['enabled'] = 'unknown';
        else
          http.unavailable = true;
        final store = MemoryAccountStore('zcode-preflight-$kind');
        final owner = await f.account(store, http);
        final id = (await owner.accounts()).single.id;
        try {
          try {
            await owner.claim(id);
          } on ZcodeFailure {}
          check(
            http.claims == 0 &&
                !((store.data['accounts'][id]['claims'] as Map).values.any(
                  (v) => v['state'] == 'pending',
                )),
            'unknown config caused an unverified or uncertain POST',
          );
        } finally {
          owner.dispose();
        }
      }
    },
  );

  await run(
    'cancelled ZCode preflight pauses without POST and no repeated automatic verifier',
    () async {
      final http = Official(),
          store = MemoryAccountStore('zcode-preflight-cancelled');
      final seeded = await f.account(store, http);
      seeded.dispose();
      var calls = 0;
      final owner = ZcodeActivityAccounts(
        store: store,
        api: ZcodeApi(http),
        now: () => f.now,
        requestVerification: (_) async {
          calls++;
          return null;
        },
      );
      try {
        await owner.tick();
        await owner.tick();
        check(
          http.claims == 0 &&
              calls == 1 &&
              (await owner.accounts()).single.status == 'verificationRequired',
          'cancelled preflight posted or repeatedly prompted',
        );
      } finally {
        owner.dispose();
      }
    },
  );

  await run(
    'ZCode account replacement during preflight prevents a stale verified POST',
    () async {
      final http = Official(),
          store = MemoryAccountStore('zcode-preflight-cas');
      final owner = await f.account(store, http);
      final id = (await owner.accounts()).single.id;
      try {
        var rejected = false;
        try {
          await owner.claim(
            id,
            verify: (_) async {
              store.data['accounts'][id]['token'] = 'synthetic-replaced-token';
              store.revision++;
              return 'synthetic-stale-proof';
            },
          );
        } on ZcodeFailure catch (e) {
          rejected = e.code == 'storage_unavailable';
        }
        check(
          rejected &&
              http.claims == 0 &&
              store.data['accounts'][id]['token'] == 'synthetic-replaced-token',
          'stale preflight overwrote or submitted the replaced account',
        );
      } finally {
        owner.dispose();
      }
    },
  );

  await run(
    'ZCode explicitly disabled or absent captcha retains a single normal claim',
    () async {
      for (final disabled in [true, false]) {
        final http = Official()..captcha = disabled ? {'enabled': false} : null;
        final owner = await f.account(
          MemoryAccountStore('zcode-preflight-off-$disabled'),
          http,
        );
        try {
          await owner.claim((await owner.accounts()).single.id);
          check(
            http.claims == 1 &&
                http.received
                        .singleWhere((r) => r.path == ZcodeApi.claimPath)
                        .verification ==
                    null,
            'disabled captcha changed normal claim semantics',
          );
        } finally {
          owner.dispose();
        }
      }
    },
  );
  exitCode = failed == 0 ? 0 : 1;
}
