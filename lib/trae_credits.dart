import 'credit_summary.dart';

CreditSummary normalizeTraeCredits(Map<String, dynamic> body, DateTime now) {
  final rows = body['user_entitlement_pack_list'];
  if (rows is! List || rows.length > 10000)
    throw const FormatException('Invalid credits');
  final seen = <String>{}, groups = <int, double>{};
  double total = 0, undated = 0;
  var unlimited = false;
  for (final row in rows) {
    if (row is! Map || row['entitlement_base_info'] is! Map)
      throw const FormatException('Invalid package');
    final base = row['entitlement_base_info'] as Map, quota = base['quota'];
    if (quota is! Map) throw const FormatException('Invalid quota');
    final limit = quota['credits_limit'];
    if (limit == null || limit == 0) continue; // Feature-only entitlement.
    final id = base['entitlement_id'];
    if (id is! String || id.isEmpty || !seen.add(id))
      throw const FormatException('Ambiguous package');
    if (limit is! num || !limit.isFinite || limit < -1)
      throw const FormatException('Invalid limit');
    final usage = row['usage'];
    if (usage != null && usage is! Map)
      throw const FormatException('Invalid usage');
    // Official CN credits normalizer treats omitted credits_amount as zero.
    final used = (usage as Map?)?['credits_amount'] ?? 0;
    if (used is! num || !used.isFinite || used < 0)
      throw const FormatException('Invalid usage');
    final raw =
        row['expire_time'] ??
        base['end_time'] ??
        base['expire_time'] ??
        row['end_time'];
    int? expiry;
    if (raw != null) {
      if (raw is! num || !raw.isFinite || raw < 0 || raw > 253402300799)
        throw const FormatException('Invalid expiry');
      if (raw > 0) expiry = (raw * 1000).round();
    }
    if (expiry != null && expiry <= now.millisecondsSinceEpoch) continue;
    final start = base['start_time'];
    if (start != null && (start is! num || !start.isFinite))
      throw const FormatException('Invalid start');
    if (start is num && start * 1000 > now.millisecondsSinceEpoch) continue;
    if (limit == -1) {
      unlimited = true;
      continue;
    }
    final remaining = (limit - used).clamp(0, limit).toDouble();
    total += remaining;
    if (expiry == null) {
      undated += remaining;
    } else if (remaining > 0) {
      groups[expiry] = (groups[expiry] ?? 0) + remaining;
    }
  }
  final dates = groups.keys.toList()..sort();
  return CreditSummary(unlimited ? null : total, undated, now, [
    for (final date in dates)
      CreditExpiry(
        DateTime.fromMillisecondsSinceEpoch(date, isUtc: true),
        groups[date]!,
      ),
  ]);
}
