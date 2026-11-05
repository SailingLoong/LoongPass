import 'credit_summary.dart';

class MiniMaxCreditsError implements Exception {
  const MiniMaxCreditsError();
  @override
  String toString() => 'MiniMax credit details unavailable';
}

CreditSummary normalizeMiniMaxCredits(
  List<Map<String, dynamic>> pages, {
  required DateTime now,
}) {
  if (pages.isEmpty) throw const MiniMaxCreditsError();
  int? count;
  final rows = <Map>[];
  for (final page in pages) {
    final expected = page['total_count'], details = page['details'];
    if (expected is! int ||
        expected < 0 ||
        expected > 10000 ||
        details is! List ||
        details.any((r) => r is! Map) ||
        count != null && count != expected)
      throw const MiniMaxCreditsError();
    count = expected;
    rows.addAll(details.cast<Map>());
  }
  if (rows.length != count) throw const MiniMaxCreditsError();
  var total = 0.0;
  final batches = <int, double>{};
  for (final row in rows) {
    final rawRemain = row['remaining_amount'];
    final remain = rawRemain is num
        ? rawRemain
        : rawRemain is String
        ? num.tryParse(rawRemain)
        : null;
    final expiry = row['expire_at_ms'];
    if (![1, 2].contains(row['credit_type']) ||
        remain is! num ||
        !remain.isFinite ||
        expiry is! num ||
        !expiry.isFinite ||
        expiry < 0 ||
        expiry > 8640000000000000)
      throw const MiniMaxCreditsError();
    if (expiry <= now.millisecondsSinceEpoch || remain <= 0) continue;
    total += remain;
    if (!total.isFinite) throw const MiniMaxCreditsError();
    final date = expiry.toInt();
    batches[date] = (batches[date] ?? 0) + remain;
  }
  final dates = batches.keys.toList()..sort();
  return CreditSummary(total, 0, now.toUtc(), [
    for (final d in dates)
      CreditExpiry(
        DateTime.fromMillisecondsSinceEpoch(d, isUtc: true),
        batches[d]!,
      ),
  ]);
}
