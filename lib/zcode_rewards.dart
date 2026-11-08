// Server-offer and bucket projections adapted from LoongPort's claim.rs and
// session_checks.rs (MIT). No scheduling, credentials or calendar inference.
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
  for (final delivery in deliveries) {
    if (delivery is! Map) throw const ZcodeFailure('invalid_response');
    final position = delivery['resource_position'];
    if (!{'banner', 'popup'}.contains(position)) continue;
    final container = delivery[position];
    if (container is! Map || container['buttons'] is! List) continue;
    for (final button in (container['buttons'] as List).take(4)) {
      final action = button is Map ? button['action'] : null;
      if (action is! Map || action['type'] != 'claim_zcode_plan') continue;
      final args = action['args'];
      if (args is! Map || !zcodeText(args['plan_id']))
        throw const ZcodeFailure('invalid_response');
      offers[args['plan_id']] = ZcodeOffer(
        args['plan_id'],
        null,
        delivery['priority'] is int ? delivery['priority'] : 0,
      );
    }
  }
  return offers.values.toList();
}

double? _amount(dynamic value) {
  final n = value is num
      ? value.toDouble()
      : value is String
      ? double.tryParse(value)
      : null;
  return n != null && n.isFinite && n >= 0 ? n : null;
}

int? _seconds(dynamic value) {
  final n = _amount(value);
  return n != null && n <= 253402300799 && n == n.truncateToDouble()
      ? n.toInt()
      : null;
}

class ZcodeBucket {
  final String label, unit;
  final double? remaining;
  final int? expiresAt;
  const ZcodeBucket(this.label, this.unit, this.remaining, this.expiresAt);
  Map<String, dynamic> toJson() => {
    'label': label,
    'unit': unit,
    'remaining': remaining,
    'expiresAt': expiresAt,
  };
  factory ZcodeBucket.fromJson(Map<String, dynamic> value) => ZcodeBucket(
    value['label'],
    value['unit'],
    _amount(value['remaining']),
    _seconds(value['expiresAt']),
  );
}

class ZcodeBalance {
  final int serverTime, checkedAt;
  final List<Map<String, dynamic>> plans;
  final List<ZcodeBucket> buckets;
  final Set<String> entitledModels;
  ZcodeBalance._(
    this.serverTime,
    this.checkedAt,
    this.plans,
    this.buckets,
    Set<String> entitledModels,
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
      // A bucket is usable only when tied to an observed active entitlement.
      if (plan == null ||
          !_usable(plan, time) ||
          expires != null && expires <= time)
        continue;
      final planEnd = _seconds(plan['ends_at']);
      final end = expires == null
          ? planEnd
          : planEnd == null
          ? expires
          : (expires < planEnd ? expires : planEnd);
      buckets.add(
        ZcodeBucket(
          zcodeText(b['show_name'])
              ? b['show_name']
              : zcodeText(plan['name'])
              ? plan['name']
              : '活动额度',
          zcodeText(b['unit_type']) ? b['unit_type'] : '单位未知',
          _amount(b['remaining_units']),
          end,
        ),
      );
      final remaining = _amount(b['remaining_units']);
      final used = _amount(b['used_units']), total = _amount(b['total_units']);
      final available = remaining != null
          ? remaining > 0
          : b['remaining_units'] == null &&
                used != null &&
                total != null &&
                used < total;
      if (available && b['capabilities'] is List) {
        for (final capability in b['capabilities']) {
          if (capability is! String) continue;
          final name = capability.trim();
          final model = name.startsWith('model:')
              ? name.substring(6).trim()
              : name.contains(':')
              ? ''
              : name;
          if (model.isNotEmpty) entitledModels.add(model.toLowerCase());
        }
      }
    }
    buckets.sort(
      (a, b) =>
          (a.expiresAt ?? 253402300799).compareTo(b.expiresAt ?? 253402300799),
    );
    return ZcodeBalance._(time, nowMs, plans, buckets, entitledModels);
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

  Map<String, dynamic>? receipt(String id, List<dynamic> previous) {
    for (final p in plans) {
      if (p['plan_id'] == id &&
          zcodeText(p['user_plan_id']) &&
          !previous.contains(p['user_plan_id']) &&
          {'active', 'expired'}.contains(p['status']))
        return p;
    }
    return null;
  }
}
