import 'package:flutter_test/flutter_test.dart';

import '../lib/credit_expiry_history.dart';
import '../lib/credit_timeline.dart';
import '../lib/plugin_accounts.dart';
import '../lib/plugin_credit_balance.dart';
import 'model_workspace_fixture.dart';
import 'workspace_usage_test.dart' show FixtureUsage;

void main() {
  test('an incomplete refresh retains the time of the last actual balance and cannot undo a settlement', () {
    final journal = <String, dynamic>{}, at = DateTime(2030, 2, 10, 12);
    final due = at.add(const Duration(hours: 2));
    CreditExpiryEvidence row(DateTime checked, {num? left, num? unused}) =>
        CreditExpiryEvidence(
          due,
          'credits',
          remaining: left,
          unused: unused,
          observedAt: checked,
        );
    final later = at.add(const Duration(hours: 1));
    updateCreditHistory(journal, 'owner', [row(at, left: 42.125)], at);
    updateCreditHistory(journal, 'owner', [row(later)], later);
    CreditExpiryEvidence stored() => CreditExpiryEvidence.read(
      (journal['expiryHistory']['owner'] as Map).values.single,
    )!;
    expect(stored().remaining, 42.125);
    expect(stored().observedAt, at);
    updateCreditHistory(journal, 'owner', [row(due, unused: 0)], due);
    updateCreditHistory(journal, 'owner', [row(later, left: 37)], due);
    expect(stored().unused, 0);
  });
  test('official package observations supersede same-date aggregate windows and preserve date precision', () {
    final now = DateTime(2030, 2, 10, 12);
    final usage = {
      'creditBatches': [
        {'id': 'A', 'at': '2030-02-10', 'unit': 'credits', 'remaining': 2.25},
        {'id': 'B', 'at': '2030-02-10', 'unit': 'credits', 'remaining': 3.125},
      ],
      'windows': [
        {'runsOutAt': '2030-02-10', 'unit': 'credits', 'runsOut': 5.375},
      ],
    };
    final rows = pluginCreditExpiryBatches(usage, {}, now);
    expect(rows.map((r) => r.amount?.amount), [2.25, 3.125]);
    expect(rows.every((r) => r.dateOnly), true);
  });
  test('source rates use the same settled grants and a missing identity prevents a false zero debit', () {
    final fixture = WorkspaceFixtureAccounts(),
        usage = FixtureUsage(),
        now = usage.now;
    final day = DateTime(now.year, now.month, now.day - 1);
    for (final (n, issued) in [(75, 100), (25, 900), (null, null)]) {
      fixture.expiryHistory.add((
        account: 'fixture',
        provider: 'loomy',
        batch: CreditExpiryEvidence(day, 'credits', unused: n, issued: issued),
      ));
    }
    final source = (provider: 'loomy', unit: 'credits');
    final start = day.toUtc().toIso8601String(),
        through = now.toUtc().toIso8601String();
    PluginAccount account(String id, Map<String, dynamic>? facts) =>
        PluginAccount(
          key: id,
          facts: {'provider': 'loomy', 'uid': id, 'registrationId': id},
          active: true,
          models: [],
          usage: facts,
        );
    fixture.accounts.addAll([
      account('A', {
        'creditSpending': {
          'unit': 'credits',
          'from': start,
          'through': through,
          'hours': [
            {'at': start, 'amount': 23.375},
          ],
        },
      }),
      account('B', null),
    ]);
    final data = CreditTimeline(fixture, now), rank = data.ranking.single;
    expect(rank.unused, 100);
    expect(rank.rate, .1);
    expect(rank.settled.length, 2);
    expect(rank.rows.length, 3);
    expect(data.spent(source, day, now), null);
    fixture.accounts.removeLast();
    expect(CreditTimeline(fixture, now).spent(source, day, now), 23.375);
    usage.dispose();
    fixture.dispose();
  });
}
