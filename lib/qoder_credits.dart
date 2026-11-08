import 'credit_summary.dart';

class QoderCredits {
  final CreditSummary packages;
  final double? planRemaining, addOnRemaining;
  final String planUnit, addOnUnit, packagesUnit;
  QoderCredits(
    this.packages,
    this.planRemaining,
    this.addOnRemaining, {
    this.planUnit = 'credits',
    this.addOnUnit = 'credits',
    this.packagesUnit = 'credits',
  });
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

  String unit(Map value) {
    final raw = value['unit'] ?? 'credits';
    if (raw is! String ||
        raw.isEmpty ||
        raw.length > 64 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(raw))
      throw const FormatException('Invalid quota unit');
    return raw;
  }

  double? quota(Object? value) {
    if (value == null) return null;
    if (value is! Map) throw const FormatException('Invalid quota');
    if (value.containsKey('remaining')) return number(value['remaining']);
    final total = number(value['total'] ?? value['cap']),
        used = number(value['used']);
    return (total - used).clamp(0, total);
  }

  final groups = <int, double>{};
  double unknown = 0;
  final rows =
      usage['dedicatedResourcePackages'] ??
      usage['dedicated_resource_packages'] ??
      const [];
  String? packagesUnit;
  void includeUnit(Map row) {
    final rowUnit = unit(row);
    if (packagesUnit != null && packagesUnit != rowUnit)
      throw const FormatException('Mixed package units');
    packagesUnit = rowUnit;
  }

  if (rows is! List || rows.length > 10000)
    throw const FormatException('Invalid packages');
  for (final row in rows) {
    if (row is! Map) throw const FormatException('Invalid package');
    if (row['available'] == false) continue;
    final remaining = quota(row)!;
    if (remaining == 0) continue;
    final raw = row['expires_at'] ?? row['expiresAt'];
    if (raw == null) {
      includeUnit(row);
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
      includeUnit(row);
      unknown += remaining;
      continue;
    }
    if (expiry <= now.millisecondsSinceEpoch) continue;
    includeUnit(row);
    groups[expiry] = (groups[expiry] ?? 0) + remaining;
  }
  final dates = groups.keys.toList()..sort();
  final plan = usage['userQuota'] ?? usage['user_quota'];
  final addOn = usage['addOnQuota'] ?? usage['add_on_quota'];
  return QoderCredits(
    CreditSummary(null, unknown, now, [
      for (final date in dates)
        CreditExpiry(
          DateTime.fromMillisecondsSinceEpoch(date, isUtc: true),
          groups[date]!,
        ),
    ]),
    quota(plan),
    quota(addOn),
    planUnit: plan is Map ? unit(plan) : 'credits',
    addOnUnit: addOn is Map ? unit(addOn) : 'credits',
    packagesUnit: packagesUnit ?? 'credits',
  );
}
