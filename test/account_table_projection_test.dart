import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/account_table_entry.dart';
import '../lib/plugin_credit_balance.dart';

void main() {
  test(
    'aggregate entries retain actionable state, callback and native units',
    () {
      final at = DateTime.utc(2099, 1, 1);
      var calls = 0;
      final entry = AccountTableEntry(
        id: 'a',
        label: 'Account',
        identity: 'id',
        balance: '0 credits',
        status: 'test',
        details: const SizedBox(),
        attention: AccountAttention.actionRequired,
        resolution: (
          label: '重新授权',
          run: () {
            calls++;
          },
        ),
        expiryBatches: [(at: at, amount: '0.25 tokens')],
      ).inApp('qoder', 'Qoder · 海外版');
      expect(entry.nextExpiry, at);
      expect(entry.upcomingExpiryAmount, '0.25 tokens');
      expect(entry.needsAttention, isTrue);
      expect(entry.attention, AccountAttention.actionRequired);
      expect(entry.expiryBatches, [(at: at, amount: '0.25 tokens')]);
      expect(calls, 0);
      entry.resolution!.run();
      expect(calls, 1);
    },
  );

  test('future batches preserve independent windows, original units and unknown amounts', () {
    final now = DateTime.utc(2026, 1, 1);
    final windows = [
      {'runsOutAt': '2026-01-03T00:00:00Z', 'unit': 'tokens'},
      {
        'runsOutAt': '2026-01-02T00:00:00Z',
        'runsOut': 76.25,
        'unit': 'credits',
      },
      {'runsOutAt': '2025-12-31T00:00:00Z', 'runsOut': 2, 'unit': 'credits'},
    ];
    final batches = pluginCreditExpiryBatches({'windows': windows}, {}, now);
    expect(batches.map((b) => (b.at, b.amount?.amount, b.amount?.unit)), [
      (DateTime.utc(2026, 1, 2), 76.25, 'credits'),
      (DateTime.utc(2026, 1, 3), null, null),
    ]);
  });
}
