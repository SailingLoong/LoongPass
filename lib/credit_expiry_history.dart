import 'dart:convert';

/// A null quantity is a known deadline without settlement evidence. A zero
/// is a reconciled batch that was fully spent, so it is omitted from losses.
class CreditExpiryEvidence {
  const CreditExpiryEvidence(
    this.at,
    this.unit, {
    this.unused,
    this.dateOnly = false,
    this.sourceId = '',
  });
  final DateTime at;
  final String unit;
  final num? unused;
  final bool dateOnly;
  final String sourceId;

  String get key => jsonEncode([timestamp, unit, sourceId]);
  String get timestamp => dateOnly
      ? at.toIso8601String().split('T').first
      : at.toUtc().toIso8601String();
  Map<String, dynamic> toJson() => {
    'at': timestamp,
    'unit': unit,
    if (unused != null) 'unused': unused,
    if (sourceId.isNotEmpty) 'id': sourceId,
  };
  static CreditExpiryEvidence? read(Object? raw) {
    if (raw is! Map || raw['at'] is! String || raw['unit'] is! String)
      return null;
    final at = DateTime.tryParse(raw['at']);
    final n = raw['unused'];
    if (at == null ||
        (raw['id'] != null && raw['id'] is! String) ||
        (raw['at'].length == 10 &&
            at.toIso8601String().split('T').first != raw['at']) ||
        (n != null && (n is! num || !n.isFinite || n < 0)))
      return null;
    return CreditExpiryEvidence(
      at.toLocal(),
      raw['unit'],
      unused: n,
      dateOnly: raw['at'].length == 10,
      sourceId: raw['id'] as String? ?? '',
    );
  }
}

typedef AccountExpiryRecord = ({
  String provider,
  String account,
  CreditExpiryEvidence batch,
});

String creditHistoryOwner(Map row) => jsonEncode([
  row['provider'],
  row['realm'],
  row['uid'],
  if ((row['uid'] ?? '') == '') row['registrationId'],
]);

/// The account facts store serializes writes. Group like units at the same
/// deadline within one official identity. Observations never replace settlements.
bool updateCreditHistory(
  Map data,
  String owner,
  Iterable<CreditExpiryEvidence> incoming,
  DateTime now,
) {
  final existing = data['expiryHistory'] as Map? ?? const {};
  final rows = Map<String, dynamic>.from(existing[owner] as Map? ?? const {});
  final local = now.toLocal(),
      cutoff = DateTime(local.year, local.month, local.day - 6);
  var changed = false;
  rows.removeWhere((_, raw) {
    final batch = CreditExpiryEvidence.read(raw);
    final drop = batch == null || batch.at.isBefore(cutoff);
    if (drop) changed = true;
    return drop;
  });
  for (final batch in incoming) {
    if (batch.at.isBefore(cutoff)) continue;
    final previous = rows[batch.key];
    if (previous is Map &&
        (batch.unused == null || previous['unused'] == batch.unused))
      continue;
    rows[batch.key] = batch.toJson();
    changed = true;
  }
  if (changed) {
    final all = Map<String, dynamic>.from(existing);
    if (rows.isEmpty) {
      all.remove(owner);
    } else {
      all[owner] = rows;
    }
    data['expiryHistory'] = all;
  }
  return changed;
}
