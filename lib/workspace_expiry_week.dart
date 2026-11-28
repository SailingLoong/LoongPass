import 'account_table_entry.dart';
import 'managed_app.dart';

typedef WorkspaceAccount = ({ManagedApp app, AccountTableEntry entry});
typedef WorkspaceExpiryBatch = ({
  WorkspaceAccount account,
  DateTime at,
  String? amount,
  bool dateOnly,
});

/// Seven local calendar days. Amounts belong to individual owner batches.
class WorkspaceExpiryWeek {
  WorkspaceExpiryWeek(List<WorkspaceAccount> accounts, DateTime now)
    : days = _calendar(now.toLocal()) {
    for (final account in accounts) {
      for (final batch in account.entry.expiryBatches) {
        final at = batch.at.toLocal();
        final day = DateTime(at.year, at.month, at.day);
        final dateOnly = account.entry.dateOnlyExpiries.contains(batch);
        final end = dateOnly ? DateTime(day.year, day.month, day.day + 1) : at;
        if (!end.isAfter(now) ||
            day.isBefore(days.first) ||
            day.isAfter(days.last))
          continue;
        (_byDay[day] ??= []).add((
          account: account,
          at: at,
          amount: batch.amount,
          dateOnly: dateOnly,
        ));
      }
    }
    for (final batches in _byDay.values) {
      batches.sort((a, b) => a.at.compareTo(b.at));
    }
  }
  final List<DateTime> days;
  final _byDay = <DateTime, List<WorkspaceExpiryBatch>>{};
  List<WorkspaceExpiryBatch> on(DateTime day) => _byDay[day] ?? const [];
  static List<DateTime> _calendar(DateTime today) => [
    for (var i = 0; i < 7; i++)
      DateTime(today.year, today.month, today.day + i),
  ];
}
