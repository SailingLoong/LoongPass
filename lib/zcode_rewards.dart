// Server-offer and bucket projections adapted from LoongPort's claim.rs and
// session_checks.rs (MIT). No scheduling, credentials or calendar inference.
import 'dart:convert';

import 'credit_expiry_history.dart';
import 'zcode_api.dart';

class ZcodeOffer {
  final String id;
  final String? name;
  final int priority;
  const ZcodeOffer(this.id, this.name, this.priority);
}

List<ZcodeOffer> zcodePreviewOffers(Map<String, dynamic> body) {
  final raw = zcodeData(body)['plans'];
  if (raw is! List || raw.length > 256)
    throw const ZcodeFailure('invalid_response');
  return [for (final value in raw) _offer(value)];
}

ZcodeOffer _offer(dynamic value) {
  if (value is! Map || !zcodeText(value['plan_id'] ?? value['planId'])) {
    throw const ZcodeFailure('invalid_response');
  }
  return ZcodeOffer(
    value['plan_id'] ?? value['planId'],
    zcodeText(value['name']) ? value['name'] : null,
    value['priority'] is int ? value['priority'] : 0,
  );
}

List<ZcodeOffer> zcodeMarketingOffers(Map<String, dynamic> body) {
  final deliveries = zcodeData(body)['deliveries'];
  if (deliveries is! List || deliveries.length > 32)
    throw const ZcodeFailure('invalid_response');
  final offers = <String, ZcodeOffer>{};
  var incomplete = false;
  for (final delivery in deliveries) {
    final position = delivery is Map ? delivery['resource_position'] : null;
    final surface = position == 'banner' || position == 'popup'
        ? delivery[position]
        : null;
    final content = surface is Map ? surface['content'] : null;
    final buttons = surface is Map
        ? surface['buttons'] ?? (content is Map ? content['buttons'] : null)
        : null;
    if (buttons is! List) {
      incomplete = true;
      continue;
    }
    // Only a button on the offered surface can initiate a claim. Media
    // metadata and the dialog displayed after success are presentation data.
    for (final button in buttons) {
      final action = button is Map ? button['action'] : null;
      if (action is! Map || !zcodeText(action['type'])) {
        incomplete = true;
        continue;
      }
      if (action['type'] != 'claim_zcode_plan') continue;
      final args = action['args'];
      if (args is! Map || !zcodeText(args['plan_id'])) {
        incomplete = true;
        continue;
      }
      final id = args['plan_id'] as String;
      final priority = delivery['priority'] is int
          ? delivery['priority'] as int
          : 0;
      if (!offers.containsKey(id) || offers[id]!.priority < priority) {
        offers[id] = ZcodeOffer(id, null, priority);
      }
    }
  }
  if (offers.isEmpty && incomplete)
    throw const ZcodeFailure('invalid_response');
  return offers.values.toList();
}

num? zcodeUnits(Object? value) {
  final n = value is num
      ? value
      : value is String
      ? num.tryParse(value)
      : null;
  return n != null && n.isFinite && n >= 0 ? n : null;
}

int? _seconds(Object? value) {
  final n = zcodeUnits(value);
  return n != null && n <= 253402300799 && n == n.truncate() ? n.toInt() : null;
}

int? zcodePlanExpiry(Map plan) => _seconds(plan['ends_at']);

DateTime? zcodeTime(Object? value) {
  final seconds = _seconds(value);
  return seconds == null || seconds == 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

Iterable<Map> zcodePlans(Map reward) =>
    (reward['plans'] as List? ?? const []).whereType<Map>();

Iterable<Map> zcodeEntitlements(Map plan) =>
    (plan['entitlements'] as List? ?? const []).whereType<Map>();

/// A recurring allowance or several independent entitlements cannot establish
/// the amount added by a single receipt.
({num amount, String unit})? zcodeReceiptAmount(Map plan) {
  final entitlement = zcodeEntitlements(plan).singleOrNull;
  if (entitlement == null || entitlement['period'] != 'one_time') return null;
  final n = zcodeUnits(entitlement['grant_units']),
      unit = entitlement['unit_type'];
  return n != null && zcodeText(unit)
      ? (amount: n, unit: unit as String)
      : null;
}

class ZcodeBucket {
  final String label, unit;
  final num? remaining, total, used;
  final int? expiresAt, periodStart, periodEnd;
  final List<String> models;
  final String? instance, planId;
  const ZcodeBucket(
    this.label,
    this.unit,
    this.remaining,
    this.expiresAt, {
    this.instance,
    this.planId,
    this.total,
    this.used,
    this.periodStart,
    this.periodEnd,
    this.models = const [],
  });
  Map<String, dynamic> toJson() => {
    'label': label,
    'unit': unit,
    'remaining': remaining,
    'expiresAt': expiresAt,
    if (total != null) 'total': total,
    if (used != null) 'used': used,
    if (periodStart != null) 'periodStart': periodStart,
    if (periodEnd != null) 'periodEnd': periodEnd,
    if (models.isNotEmpty) 'models': models,
    if (instance != null) 'instance': instance,
    if (planId != null) 'planId': planId,
  };
  factory ZcodeBucket.fromJson(Map value) => ZcodeBucket(
    value['label'],
    value['unit'],
    zcodeUnits(value['remaining']),
    _seconds(value['expiresAt']),
    total: zcodeUnits(value['total']),
    used: zcodeUnits(value['used']),
    periodStart: _seconds(value['periodStart']),
    periodEnd: _seconds(value['periodEnd']),
    models: (value['models'] as List? ?? const []).whereType<String>().toList(),
    instance: value['instance'] as String?,
    planId: value['planId'] as String?,
  );
}

Iterable<ZcodeBucket> zcodeBuckets(Map reward) sync* {
  for (final b in reward['buckets'] as List? ?? const []) {
    if (b is Map && b['label'] is String && b['unit'] is String)
      yield ZcodeBucket.fromJson(b);
  }
}

class ZcodeBalance {
  final int serverTime, checkedAt;
  final List<Map<String, dynamic>> plans;
  final List<ZcodeBucket> buckets;
  final Set<String> entitledModels;
  final List<CreditExpiryEvidence> expiryEvidence;
  ZcodeBalance._(
    this.serverTime,
    this.checkedAt,
    this.plans,
    this.buckets,
    Set<String> entitledModels,
    this.expiryEvidence,
  ) : entitledModels = Set.unmodifiable(entitledModels);
  factory ZcodeBalance.parse(Map<String, dynamic> body, int nowMs) {
    final data = zcodeData(body), raw = zcodeData(body)['plans'];
    if (raw is! List || raw.length > 1024)
      throw const ZcodeFailure('invalid_response');
    final time = _seconds(data['server_time']);
    if (time == null) throw const ZcodeFailure('invalid_response');
    final plans = <Map<String, dynamic>>[];
    final ids = <String>{};
    for (final p in raw) {
      if (p is! Map<String, dynamic> ||
          !zcodeText(p['plan_id']) ||
          p.containsKey('user_plan_id') &&
              (!zcodeText(p['user_plan_id']) || !ids.add(p['user_plan_id'])) ||
          !zcodeText(p['status'])) {
        throw const ZcodeFailure('invalid_response');
      }
      final normalized = Map<String, dynamic>.from(p);
      for (final field in ['starts_at', 'ends_at']) {
        final value = _seconds(p[field]);
        if (p[field] != null && value == null)
          throw const ZcodeFailure('invalid_response');
        normalized[field] = value;
      }
      plans.add(normalized);
    }
    final buckets = <ZcodeBucket>[];
    final evidence = <String, CreditExpiryEvidence>{};
    final ambiguous = <String>{};
    final entitledModels = <String>{};
    final rawBuckets = data['balances'];
    if (rawBuckets != null && rawBuckets is! List)
      throw const ZcodeFailure('invalid_response');
    for (final b in (rawBuckets as List? ?? [])) {
      if (b is! Map ||
          b.containsKey('user_plan_id') && !zcodeText(b['user_plan_id']))
        throw const ZcodeFailure('invalid_response');
      final plan = _planForBucket(plans, b);
      final expires = _seconds(b['expires_at']);
      final history = _expiryEvidence(plan, b, time);
      if (history != null && !ambiguous.contains(history.key)) {
        final old = evidence[history.key];
        if (old != null &&
            (!zcodeText(b['entitlement_id']) || old.unused != history.unused)) {
          ambiguous.add(history.key);
          evidence[history.key] = CreditExpiryEvidence(
            history.at,
            history.unit,
            sourceId: history.sourceId,
            dateOnly: history.dateOnly,
          );
        } else {
          evidence[history.key] = history;
        }
      }
      // A bucket is usable only when tied to an observed active entitlement.
      if (plan == null ||
          !_usable(plan, time) ||
          expires != null && expires <= time)
        continue;
      final planEnd = zcodePlanExpiry(plan);
      final end = expires == null
          ? planEnd
          : planEnd == null
          ? expires
          : (expires < planEnd ? expires : planEnd);
      final reportedUsed = zcodeUnits(b['used_units']),
          total = zcodeUnits(b['total_units']),
          left = zcodeUnits(b['remaining_units']);
      final remaining = b['remaining_units'] != null
          ? left
          : reportedUsed != null && total != null && reportedUsed <= total
          ? total - reportedUsed
          : null;
      final used =
          b['used_units'] == null &&
              total != null &&
              left != null &&
              left <= total
          ? total - left
          : reportedUsed;
      final models = <String>{};
      for (final capability
          in (b['capabilities'] is List ? b['capabilities'] as List : const [])
              .whereType<String>()) {
        final name = capability.trim();
        final model = name.startsWith('model:')
            ? name.substring(6).trim()
            : name.contains(':')
            ? ''
            : name;
        if (model.isNotEmpty) models.add(model);
      }
      buckets.add(
        ZcodeBucket(
          zcodeText(b['show_name'])
              ? b['show_name']
              : zcodeText(plan['name'])
              ? plan['name']
              : '活动额度',
          zcodeText(b['unit_type']) ? b['unit_type'] : '单位未知',
          remaining,
          end,
          total: total,
          used: used,
          periodStart: _seconds(b['period_start']),
          periodEnd: _seconds(b['period_end']),
          models: models.toList(),
          planId: plan['plan_id'] as String?,
          instance: plan['user_plan_id'] as String?,
        ),
      );
      if (remaining != null && remaining > 0)
        entitledModels.addAll(models.map((name) => name.toLowerCase()));
    }
    buckets.sort(
      (a, b) =>
          (a.expiresAt ?? 253402300799).compareTo(b.expiresAt ?? 253402300799),
    );
    return ZcodeBalance._(
      time,
      nowMs,
      plans,
      buckets,
      entitledModels,
      List.unmodifiable(evidence.values),
    );
  }

  /// Settle only an officially expired instance with reconciled final units.
  /// Reading the last active balance after a local clock boundary is insufficient.
  static CreditExpiryEvidence? _expiryEvidence(
    Map? plan,
    Map b,
    int serverTime,
  ) {
    final instance = b['user_plan_id'], unit = b['unit_type'];
    if (plan == null ||
        !zcodeText(instance) ||
        plan['user_plan_id'] != instance ||
        !zcodeText(unit))
      return null;
    final bucketEnd = _seconds(b['expires_at']),
        planEnd = zcodePlanExpiry(plan);
    final raw = b['expires_at'];
    final dayOnly =
        raw is String && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw);
    final boundaries = [
      if (bucketEnd != null) bucketEnd,
      if (planEnd != null) planEnd,
    ]..sort();
    DateTime? at = boundaries.isEmpty
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            boundaries.first * 1000,
            isUtc: true,
          );
    var onlyDate = false;
    if (dayOnly) {
      final civil = DateTime.tryParse(raw);
      if (civil == null || civil.toIso8601String().split('T').first != raw)
        return null;
      if (at == null || !at.toLocal().isBefore(civil)) {
        at = civil;
        onlyDate = true;
      }
    }
    if (at == null || (raw != null && bucketEnd == null && !dayOnly))
      return null;
    final end = onlyDate ? DateTime(at.year, at.month, at.day + 1) : at;
    final closed =
        plan['status'] == 'expired' &&
        end.millisecondsSinceEpoch <= serverTime * 1000;
    num? units(Object? raw) {
      final n = raw is num
          ? raw
          : raw is String
          ? num.tryParse(raw)
          : null;
      return n != null && n.isFinite && n >= 0 ? n : null;
    }

    final total = units(b['total_units']),
        used = units(b['used_units']),
        left = units(b['remaining_units']);
    num? unused;
    if (closed && total != null && used != null && used <= total) {
      final difference = total - used;
      if (b['remaining_units'] == null ||
          left != null && (difference == left || used + left == total)) {
        unused = left ?? difference;
      }
    }
    return CreditExpiryEvidence(
      at,
      unit,
      unused: unused,
      issued: total,
      remaining: end.millisecondsSinceEpoch > serverTime * 1000 ? left : null,
      observedAt: DateTime.fromMillisecondsSinceEpoch(serverTime * 1000),
      dateOnly: onlyDate,
      sourceId: jsonEncode([instance, b['entitlement_id'], b['period_start']]),
    );
  }

  static Map<String, dynamic>? _planForBucket(
    List<Map<String, dynamic>> plans,
    Map bucket,
  ) {
    final instance = bucket['user_plan_id'];
    if (instance != null) {
      final exact = plans.where((p) => p['user_plan_id'] == instance);
      if (exact.length == 1) return exact.single;
    }
    // Older balances identify only the plan. A repeated plan id cannot prove
    // which entitlement owns this bucket; explicit instance ids never disagree.
    final candidates = plans.where((p) => p['plan_id'] == bucket['plan_id']);
    if (candidates.length != 1) return null;
    final plan = candidates.single;
    return instance != null && plan['user_plan_id'] != null ? null : plan;
  }

  static bool _held(Map<String, dynamic> p, int now) =>
      p['status'] == 'active' &&
      (_seconds(p['ends_at']) == null || _seconds(p['ends_at'])! > now);
  static bool _usable(Map<String, dynamic> p, int now) =>
      p['status'] == 'active' &&
      (_seconds(p['starts_at']) == null || _seconds(p['starts_at'])! <= now) &&
      (_seconds(p['ends_at']) == null || _seconds(p['ends_at'])! > now);
  Map<String, dynamic>? active(String id) {
    for (final p in plans) {
      if (p['plan_id'] == id && _held(p, serverTime)) return p;
    }
    return null;
  }

  Map<String, dynamic>? receipt(
    String id,
    List<dynamic> previous, {
    Object? instance,
    bool heldOnly = false,
  }) {
    Map<String, dynamic>? receipt;
    for (final p in plans) {
      if (p['plan_id'] == id &&
          zcodeText(p['user_plan_id']) &&
          (instance == null
              ? !previous.contains(p['user_plan_id'])
              : p['user_plan_id'] == instance) &&
          (heldOnly
              ? _held(p, serverTime)
              : {'active', 'expired'}.contains(p['status']))) {
        if (receipt != null) return null;
        receipt = p;
      }
    }
    return receipt;
  }
}
