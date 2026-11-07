import 'credit_summary.dart';

class QoderCredits {
  final CreditSummary packages;
  final double? planRemaining, addOnRemaining;
  QoderCredits(this.packages, this.planRemaining, this.addOnRemaining);
}

/// /sash/api/v2/me/usage describes plan/add-on totals and dedicated packages.
/// Packages can overlap those totals. Never add them together or apply a plan
/// renewal date to add-on credits; only per-package expiry is authoritative.
QoderCredits normalizeQoderCredits(Map<String, dynamic> body, DateTime now) {
  final usage = body['qoderUsage'];
  if (body['displayMode'] != 'qoder' || usage is! Map)
    throw const FormatException('Unsupported usage');
  double number(Object? value) {
    if (value is! num || !value.isFinite || value < 0)
      throw const FormatException('Invalid amount');
    return value.toDouble();
  }

  double? quota(Object? value) {
    if (value == null) return null;
    if (value is! Map) throw const FormatException('Invalid quota');
    if (value.containsKey('remaining')) return number(value['remaining']);
    final total = number(value['total']), used = number(value['used']);
    return (total - used).clamp(0, total);
  }

  final groups = <int, double>{};
  double unknown = 0;
  final rows = usage['dedicatedResourcePackages'] ?? const [];
  if (rows is! List || rows.length > 10000)
    throw const FormatException('Invalid packages');
  for (final row in rows) {
    if (row is! Map) throw const FormatException('Invalid package');
    if (row['available'] == false) continue;
    final remaining = number(row['remaining']);
    if (remaining == 0) continue;
    final raw = row['expires_at'] ?? row['expiresAt'];
    if (raw == null) {
      unknown += remaining;
      continue;
    }
    final int expiry;
    if (raw is num && raw.isFinite && raw > 0) {
      expiry = (raw < 10000000000 ? raw * 1000 : raw).round();
    } else if (raw is String &&
        RegExp(r'(?:Z|[+-]\d{2}:?\d{2})$').hasMatch(raw)) {
      final date = DateTime.tryParse(raw);
      if (date == null) throw const FormatException('Invalid expiry');
      expiry = date.millisecondsSinceEpoch;
    } else {
      throw const FormatException('Invalid expiry');
    }
    // The official service uses year 9999 for an unspecified renewal/expiry.
    if (expiry >= DateTime.utc(9999).millisecondsSinceEpoch) {
      unknown += remaining;
      continue;
    }
    if (expiry <= now.millisecondsSinceEpoch) continue;
    groups[expiry] = (groups[expiry] ?? 0) + remaining;
  }
  final dates = groups.keys.toList()..sort();
  return QoderCredits(
    CreditSummary(null, unknown, now, [
      for (final date in dates)
        CreditExpiry(
          DateTime.fromMillisecondsSinceEpoch(date, isUtc: true),
          groups[date]!,
        ),
    ]),
    quota(usage['userQuota']),
    quota(usage['addOnQuota']),
  );
}
