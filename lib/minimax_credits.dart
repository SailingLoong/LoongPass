import 'credit_summary.dart';

class MiniMaxCreditsError implements Exception {
  const MiniMaxCreditsError();
  @override
  String toString() => 'MiniMax credit details unavailable';
}

({int totalCount, List<Map> rows}) parseMiniMaxCreditPage(
  Map<String, dynamic> page,
) {
  final count = page['total_count'];
  if (count is! int || count < 0 || count > 10000)
    throw const MiniMaxCreditsError();
  var verified = false;
  for (final entry in [('base_resp', 'status_code'), ('statusInfo', 'code')]) {
    if (!page.containsKey(entry.$1)) continue;
    final status = page[entry.$1];
    if (status is! Map || status[entry.$2] != 0)
      throw const MiniMaxCreditsError();
    verified = true;
  }
  final details = page['details'];
  if (!page.containsKey('details') && count == 0 && verified)
    return (totalCount: 0, rows: const []);
  if (details is! List || details.any((row) => row is! Map))
    throw const MiniMaxCreditsError();
  return (totalCount: count, rows: details.cast<Map>());
}

CreditSummary normalizeMiniMaxCredits(
  List<Map<String, dynamic>> pages, {
  required DateTime now,
}) {
  if (pages.isEmpty) throw const MiniMaxCreditsError();
  int? count;
  final rows = <Map>[];
  for (final page in pages) {
    final parsed = parseMiniMaxCreditPage(page);
    if (count != null && count != parsed.totalCount)
      throw const MiniMaxCreditsError();
    count = parsed.totalCount;
    rows.addAll(parsed.rows);
  }
  if (rows.length != count) throw const MiniMaxCreditsError();
  var total = 0.0;
  final batches = <int, double>{};
  for (final row in rows) {
    var rawRemain = row['remaining_amount'];
    if (rawRemain is String && rawRemain.contains(',')) {
      if (!RegExp(r'^\d{1,3}(?:,\d{3})+(?:\.\d+)?$').hasMatch(rawRemain.trim()))
        throw const MiniMaxCreditsError();
      rawRemain = rawRemain.replaceAll(',', '');
    }
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
