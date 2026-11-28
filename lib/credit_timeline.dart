import 'credit_expiry_history.dart';
import 'magpie_usage.dart';
import 'plugin_accounts.dart';

typedef CreditSource = ({String provider, String unit});
CreditSource creditSource(AccountExpiryRecord row) =>
    (provider: row.provider, unit: row.batch.unit);

class CreditSourceTotals {
  CreditSourceTotals(this.source, this.rows);
  final CreditSource source;
  final List<AccountExpiryRecord> rows;
  Iterable<CreditExpiryEvidence> get settled =>
      rows.map((r) => r.batch).where((b) => b.unused != null);
  num get unused => settled.fold<num>(0, (sum, b) => sum + b.unused!);
  double? get rate {
    final facts = settled.toList();
    if (facts.isEmpty || facts.any((b) => b.issued == null)) return null;
    final issued = facts.fold<num>(0, (sum, b) => sum + b.issued!);
    return issued > 0 ? unused / issued : null;
  }
}

class CreditTimeline {
  CreditTimeline(PluginAccounts accounts, this.now) {
    final first = DateTime(now.year, now.month, now.day - 6);
    for (final row in accounts.expiryHistory) {
      if (!row.batch.at.isBefore(first) && !row.batch.end.isAfter(now))
        past.add(row);
    }
    final owners = <String>{};
    for (final account in accounts.accounts) {
      if (!owners.add(creditHistoryOwner(account.facts))) continue;
      final ledger = account.usage?['creditSpending'];
      spending
          .putIfAbsent(account.provider, () => [])
          .add(ledger is Map ? ledger : null);
      for (final b in account.creditExpiriesAt(now)) {
        final evidence = CreditExpiryEvidence(
          b.at.toLocal(),
          b.amount?.unit ?? b.reportedUnit ?? '',
          remaining: b.amount?.amount,
          issued: b.issued,
          sourceId: b.sourceId,
          observedAt: account.creditExpiryObservedAt,
          dateOnly: b.dateOnly,
        );
        final row = (
          provider: account.provider,
          account: account.label,
          batch: evidence,
        );
        future.add(row);
        accountKeys[row] = account.key;
      }
    }
    future.sort((a, b) => a.batch.at.compareTo(b.batch.at));
    final bySource = <CreditSource, List<AccountExpiryRecord>>{};
    for (final r in past) {
      bySource.putIfAbsent(creditSource(r), () => []).add(r);
    }
    ranking.addAll(
      bySource.entries.map((e) => CreditSourceTotals(e.key, e.value)),
    );
    ranking.sort((a, b) {
      final rate = (b.rate ?? -1).compareTo(a.rate ?? -1);
      if (rate != 0) return rate;
      final verified = a.settled.isEmpty == b.settled.isEmpty
          ? 0
          : (a.settled.isEmpty ? 1 : -1);
      return verified != 0
          ? verified
          : a.source.provider.compareTo(b.source.provider);
    });
  }
  final DateTime now;
  final accountKeys = <AccountExpiryRecord, String>{};
  final past = <AccountExpiryRecord>[], future = <AccountExpiryRecord>[];
  final ranking = <CreditSourceTotals>[];
  final spending = <String, List<Map?>>{};
  Iterable<AccountExpiryRecord> get records => past.followedBy(future);
  Set<CreditSource> get sources => {
    for (final r in records) creditSource(r),
    for (final item in spending.entries)
      for (final ledger in item.value.whereType<Map>())
        if (ledger['unit'] is String)
          (provider: item.key, unit: ledger['unit'] as String),
  };
  bool bills(CreditSource? source) =>
      source != null &&
      (spending[source.provider]?.any((l) => l?['unit'] == source.unit) ??
          false);

  /// A total needs a covered interval for every saved identity of this source.
  /// For the open bucket use each account's latest observation in that bucket.
  num? spent(CreditSource source, DateTime start, DateTime end) {
    if (start.isAfter(now)) return null;
    final accounts = spending[source.provider];
    if (accounts == null || accounts.isEmpty) return null;
    num amount = 0;
    for (final ledger in accounts) {
      if (ledger == null ||
          ledger['unit'] != source.unit ||
          ledger['hours'] is! List)
        return null;
      final from = DateTime.tryParse(ledger['from']?.toString() ?? ''),
          through = DateTime.tryParse(ledger['through']?.toString() ?? '');
      if (from == null ||
          through == null ||
          from.isAfter(start) ||
          through.isBefore(start) ||
          (!end.isAfter(now) && through.isBefore(end)))
        return null;
      for (final row in ledger['hours'] as List) {
        if (row is! Map) return null;
        final at = DateTime.tryParse(row['at']?.toString() ?? ''),
            n = row['amount'];
        if (at == null || n is! num || !n.isFinite || n < 0) return null;
        if (!at.isBefore(start) && at.isBefore(end)) amount += n;
      }
    }
    return amount;
  }
}

class TimelineBucket {
  TimelineBucket(
    this.start,
    this.end,
    this.usage,
    this.rows,
    this.now,
    this.count,
  );
  final DateTime start, end, now;
  final num? usage;
  final bool count;
  final List<AccountExpiryRecord> rows;
  Iterable<CreditExpiryEvidence> get knownLoss => rows
      .map((r) => r.batch)
      .where((b) => !b.end.isAfter(now) && b.unused != null && b.unused! > 0);
  Iterable<CreditExpiryEvidence> get upcoming => rows
      .map((r) => r.batch)
      .where((b) => b.end.isAfter(now) && b.remaining != null);
  int get unknown => rows
      .where(
        (r) => r.batch.end.isAfter(now)
            ? r.batch.remaining == null
            : r.batch.unused == null,
      )
      .length;
  num get loss => count
      ? knownLoss.length
      : knownLoss.fold<num>(0, (s, b) => s + b.unused!);
  num get forecast => count
      ? upcoming.length
      : upcoming.fold<num>(0, (s, b) => s + b.remaining!);
}

List<TimelineBucket> creditTimelineBuckets(
  CreditTimeline data,
  MagpieUsage usage,
  DateTime center, {
  required bool hourly,
  required CreditSource? source,
  required bool debit,
}) {
  final date = usageDate(center),
      next = DateTime(date.year, date.month, date.day + 1);
  final starts = hourly
      ? [
          for (
            var d = date;
            d.isBefore(next);
            d = d.add(const Duration(hours: 1))
          )
            d,
          next,
        ]
      : [
          for (var i = -6; i <= 7; i++)
            DateTime(date.year, date.month, date.day + i),
        ];
  final records = data.records
      .where((r) => source == null || creditSource(r) == source)
      .toList();
  final buckets = <TimelineBucket>[];
  for (var i = 0; i < starts.length - 1; i++) {
    final start = starts[i],
        end = starts[i + 1],
        day = usage.day(usageDate(start));
    num? measured;
    if (!start.isAfter(data.now)) {
      if (debit && source != null) {
        measured = data.spent(source, start, end);
      } else if (day != null && !day.checkedAt.isBefore(start)) {
        measured = hourly
            ? day.hours
                  .where((h) => h.at.isAtSameMomentAs(start))
                  .firstOrNull
                  ?.totals
                  .calls
            : day.totals.calls;
      }
    }
    buckets.add(
      TimelineBucket(
        start,
        end,
        measured,
        records
            .where(
              (r) =>
                  (!hourly || !r.batch.dateOnly) &&
                  !r.batch.at.isBefore(start) &&
                  r.batch.at.isBefore(end),
            )
            .toList(),
        data.now,
        source == null,
      ),
    );
  }
  return buckets;
}
