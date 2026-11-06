import 'package:flutter_test/flutter_test.dart';
import '../lib/trae_accounts.dart';
import '../lib/minimax_accounts.dart';
import 'minimax_accounts_checks.dart' as minimax;
import 'synthetic_fixture.dart' as fixture;
import 'memory_account_store.dart';
import '../lib/qoder_device_accounts.dart';
import 'qoder_cn_checks.dart' as qoder;
import '../lib/zcode_activity_accounts.dart';

void main() {
  test(
    'ZCode retains confirmed history after rebinding without inventing receipt amounts or times',
    () {
      final account = ZcodeActivityAccount({
        'id': 'synthetic',
        'uid': 'synthetic',
        'family': 'bigmodel',
        'label': 'Test',
        'status': 'pending',
        'automatic': false,
        'context': {'deviceMid': '11111111-1111-4111-8111-111111111111'},
        'claims': {
          'new': {'state': 'pending', 'submittedAt': 100000},
        },
        'bindingHistory': [
          {
            'claims': {
              'old': {
                'state': 'claimed',
                'submittedAt': 90000,
                'endsAt': 200000,
              },
            },
          },
        ],
        'buckets': [
          {
            'label': '订阅',
            'unit': 'tokens',
            'remaining': 620,
            'expiresAt': 200000,
          },
        ],
      });
      expect(account.latestClaim, isNotNull);
      expect(account.latestClaim?.amount, isNull);
      expect(account.latestClaim?.confirmedAt, isNull);
      expect(account.latestClaim?.display, contains('时间未知'));
    },
  );
  test(
    'Qoder retains its receipt when the same campaign reopens and the next send is unknown',
    () async {
      var now = 100000;
      final native = qoder.Native(), http = qoder.Transport();
      final owner = QoderDeviceAccounts(
        native: native,
        transport: http,
        nowMs: () => now,
      );
      await owner.startLogin();
      await owner.pollLogin();
      await owner.claim('account-a');
      http.rows.single['claimStatus'] = 'CLAIMED';
      await owner.claim('account-a');
      now += 1000;
      http.rows.single['claimStatus'] = 'CLAIMABLE';
      http.failPost = true;
      await owner.claim('account-a');
      final account = (await owner.accountViews()).single;
      expect(account.outcome, 'unknown');
      expect(account.latestClaim?.confirmedAt?.millisecondsSinceEpoch, 100000);
      expect(account.latestClaim?.amount, isNull);
      owner.dispose();
    },
  );
  test(
    'MiniMax retains amount and confirmation time after next-day failure and restart',
    () async {
      var now = 100000;
      final document = MemoryAccountStore('receipt-history');
      final http = minimax.FakeHttp();
      MiniMaxAccounts open() => MiniMaxAccounts(
        store: MiniMaxAccountStore(document),
        http: http,
        nowMs: () => now,
      );
      final owner = open();
      final account = await owner.save(
        await owner.verifySource(
          () async => MiniMaxCredential.parse(
            fixture.bytes(row: fixture.record()..['expiresAtMs'] = 999999999),
            sourcePath: fixture.path(fixture.MiniMaxRegion.cn),
            region: 'cn',
            nowMs: now,
          ),
          confirmed: true,
        ),
        confirmed: true,
      );
      final success = await owner.claim(account.id);
      expect(success.latestClaim?.amount, 10);
      expect(success.latestClaim?.confirmedAt?.millisecondsSinceEpoch, 100000);
      now += 86400000;
      http.loseClaim = true;
      expect((await owner.claim(account.id)).status, 'unknown');
      owner.dispose();
      final restored = open();
      final receipt = (await restored.list()).single.latestClaim;
      expect(receipt?.amount, 10);
      expect(receipt?.unit, '积分');
      expect(receipt?.confirmedAt?.millisecondsSinceEpoch, 100000);
      restored.dispose();
    },
  );
  test('last successful receipt survives a later unknown attempt', () {
    final account = TraeAccount({
      'uid': 'synthetic',
      'label': 'Synthetic',
      'owner': 'officialClient',
      'automatic': false,
      'outcome': 'unknown',
      'credited': null,
      'claims': {
        '2026-11-05': {'outcome': 'claimed', 'credited': 125},
        '2026-11-06': {'outcome': 'unknown', 'credited': null},
      },
    });
    expect(account.latestClaim?.amount, 125);
    expect(account.latestClaim?.day, '2026-11-05');
    expect(account.latestClaim?.confirmedAt, isNull);
    expect(account.latestClaim?.display, contains('时间未知'));
  });
  test('an observed check-in is not a confirmed LoongPass receipt', () {
    final account = TraeAccount({
      'uid': 'synthetic',
      'label': 'Synthetic',
      'owner': 'officialClient',
      'automatic': false,
      'outcome': 'observedClaimed',
      'claims': {
        '2026-11-06': {'outcome': 'observedClaimed'},
      },
    });
    expect(account.latestClaim, isNull);
  });
}
