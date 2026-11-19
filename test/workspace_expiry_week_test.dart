import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/account_table_entry.dart';
import '../lib/account_workspace_registry.dart';
import '../lib/managed_app.dart';
import '../lib/workspace_expiry_week.dart';

void main() {
  test('local calendar crosses year end and keeps individual batch values', () {
    final now = DateTime(2099, 12, 31, 12);
    final tomorrow = DateTime(2100, 1, 1, 8);
    final registry = AccountWorkspaceRegistry();
    addTearDown(registry.dispose);
    registry.publish(ManagedApp.workbuddy, Object(), [
      AccountTableEntry(
        id: 'a',
        label: 'A',
        identity: '',
        balance: '',
        status: '',
        details: const SizedBox(),
        expiryBatches: [
          (
            at: tomorrow.add(const Duration(hours: 1)),
            amount: '160.25 credits',
          ),
          (at: tomorrow.toUtc(), amount: '0.75 credits'),
          (at: now.subtract(const Duration(seconds: 1)), amount: '999 credits'),
          (at: DateTime(2100, 1, 7), amount: '3 credits'),
        ],
      ),
    ]);
    registry.publish(ManagedApp.zcode, Object(), [
      AccountTableEntry(
        id: 'a',
        label: 'B',
        identity: '',
        balance: '',
        status: '',
        details: const SizedBox(),
        expiryAt: tomorrow,
        expiringAmount: '500000000 token',
      ),
    ]);
    final week = WorkspaceExpiryWeek(registry.accounts, now);
    expect(week.days.last, DateTime(2100, 1, 6));
    expect(week.on(week.days.first), isEmpty);
    final batches = week.on(week.days[1]);
    expect(
      batches.map((b) => (b.account.entry.id, b.amount)),
      unorderedEquals([
        ('workbuddy/a', '160.25 credits'),
        ('workbuddy/a', '0.75 credits'),
        ('zcode/a', '500000000 token'),
      ]),
    );
    expect(batches.last.at, tomorrow.add(const Duration(hours: 1)));
  });
}
