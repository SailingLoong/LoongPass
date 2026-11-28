import 'dart:convert';

/// A null quantity is a known deadline without settlement evidence. A zero
/// is a reconciled batch that was fully spent, so it is omitted from losses.
class CreditExpiryEvidence {
  const CreditExpiryEvidence(
    this.at,
    this.unit, {
    this.unused,
    this.issued,
    this.remaining,
    this.observedAt,
    this.dateOnly = false,
    this.sourceId = '',
  });
  final DateTime at;
  final String unit;
  final num? unused, issued, remaining;
  final DateTime? observedAt;
  final bool dateOnly;
  final String sourceId;

  DateTime get end => dateOnly ? DateTime(at.year, at.month, at.day + 1) : at;

  String get key => jsonEncode([timestamp, unit, sourceId]);
  String get timestamp => dateOnly
      ? at.toIso8601String().split('T').first
      : at.toUtc().toIso8601String();
  Map<String, dynamic> toJson() => {
    'at': timestamp,
    'unit': unit,
    if (unused != null) 'unused': unused,
    if (issued != null) 'issued': issued,
    if (remaining != null) 'remaining': remaining,
    if (observedAt != null) 'observedAt': observedAt!.toUtc().toIso8601String(),
    if (sourceId.isNotEmpty) 'id': sourceId,
  };
  static CreditExpiryEvidence? read(Object? raw) {
    if (raw is! Map || raw['at'] is! String || raw['unit'] is! String)
      return null;
    final at = DateTime.tryParse(raw['at']);
    final n = raw['unused'],
        issued = raw['issued'],
        remaining = raw['remaining'];
    final observed = DateTime.tryParse(raw['observedAt']?.toString() ?? '');
    if (at == null ||
        (raw['id'] != null && raw['id'] is! String) ||
        (raw['at'].length == 10 &&
            at.toIso8601String().split('T').first != raw['at']) ||
        [
          n,
          issued,
          remaining,
        ].any((v) => v != null && (v is! num || !v.isFinite || v < 0)) ||
        (n != null && issued != null && n > issued))
      return null;
    return CreditExpiryEvidence(
      at.toLocal(),
      raw['unit'],
      unused: n,
      issued: issued,
      remaining: remaining,
      observedAt: observed?.toLocal(),
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
    final next = batch.toJson();
    if (previous is Map) {
      final old = CreditExpiryEvidence.read(previous);
      if (old?.unused != null && batch.unused == null) continue;
      if (batch.unused == null &&
          old?.observedAt != null &&
          (batch.observedAt == null ||
              batch.observedAt!.isBefore(old!.observedAt!)))
        continue;
      if (batch.unused != null &&
          batch.unused == old?.unused &&
          batch.issued == old?.issued)
        continue;
      if (batch.unused == null &&
          batch.remaining == null &&
          old?.remaining != null) {
        next['remaining'] = old!.remaining;
        if (old.observedAt != null)
          next['observedAt'] = old.observedAt!.toUtc().toIso8601String();
      }
      if (batch.issued == null &&
          old?.issued != null &&
          (batch.unused ?? 0) <= old!.issued!)
        next['issued'] = old.issued;
      if (next.length == previous.length &&
          next.entries.every((e) => previous[e.key] == e.value))
        continue;
    }
    rows[batch.key] = next;
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
