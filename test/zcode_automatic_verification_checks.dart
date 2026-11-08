import 'dart:async';
import 'dart:convert';

import '../lib/zcode_activity_accounts.dart';
import '../lib/zcode_api.dart';
import 'memory_account_store.dart';
import 'zcode_activities_checks.dart' as fixture;

Future<void> main() async {
  for (final outcome in ['success', 'human', 'unknown', 'closed']) {
    final store = MemoryAccountStore('automatic-verification-$outcome');
    final http = fixture.FakeZcode()
      ..captchaRequired = true
      ..claimHttp = 400
      ..claimCode = 3007
      ..acceptVerification = true;
    final seed = await fixture.account(store, http);
    seed.dispose();
    var verifications = 0;
    final waiting = Completer<String?>();
    final owner = ZcodeActivityAccounts(
      store: store,
      api: ZcodeApi(http),
      now: () => fixture.now,
      requestVerification: (config) async {
        verifications++;
        fixture.check(
          config.values.length == 3,
          'only public config crosses bridge',
        );
        if (outcome == 'human') return null;
        if (outcome == 'closed') return waiting.future;
        if (outcome == 'unknown') {
          http.loseReply = true;
          http.revealReceipt = false;
        }
        return 'synthetic-single-use-proof';
      },
    );
    final tick = owner.tick();
    if (outcome == 'closed') {
      while (verifications == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      owner.dispose();
      waiting.complete('synthetic-single-use-proof');
    }
    await tick;
    fixture.check(
      verifications == 1,
      'known-required preflight tries the SDK once',
    );
    fixture.check(
      http.claims == (['human', 'closed'].contains(outcome) ? 0 : 1),
      'only a returned proof permits the first claim',
    );
    fixture.check(
      !jsonEncode(store.data).contains('synthetic-single-use-proof'),
      'proof is never persisted',
    );
    if (outcome != 'closed') {
      final account = (await owner.accounts()).single;
      fixture.check(
        account.status ==
            switch (outcome) {
              'success' => 'claimed',
              'human' => 'verificationRequired',
              _ => 'pending',
            },
        'outcome is truthful',
      );
      final claims = http.claims;
      await owner.tick();
      fixture.check(
        http.claims == claims && verifications == 1,
        'later ticks never repeat a paused or uncertain verification',
      );
      owner.dispose();
    }
  }
  print('ZCode automatic verification checks passed');
}
