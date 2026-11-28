import 'credit_expiry_history.dart';
import 'zcode_rewards.dart';

/// A quantity from the pinned native usage contract, never parsed from display
/// text or percentage usage. The provider retains ownership of the snapshot.
class PluginCreditBalance {
  const PluginCreditBalance(this.amount, this.unit);
  final num amount;
  final String unit;
}

class PluginCreditExpiry {
  const PluginCreditExpiry(
    this.at,
    this.amount, {
    this.dateOnly = false,
    this.reportedUnit,
    this.sourceId = '',
    this.issued,
  });
  final DateTime at;
  final PluginCreditBalance? amount;
  final bool dateOnly;
  final String? reportedUnit;
  final String sourceId;
  final num? issued;
  DateTime get end => dateOnly ? DateTime(at.year, at.month, at.day + 1) : at;
}

num? _number(Object? value) => value is num && value.isFinite ? value : null;

PluginCreditBalance? pluginWindowBalance(Map value) {
  final unit = value['unit'];
  if (unit is! String || unit.trim().isEmpty) return null;
  final remaining = pluginWindowRemaining(value);
  return remaining == null ? null : PluginCreditBalance(remaining, unit);
}

num? pluginWindowRemaining(Map value) {
  final balance = _number(value['balance']);
  if (balance != null) return balance;
  final limit = _number(value['limit']), spent = _number(value['amount']);
  if (limit == null || spent == null) return null;
  return limit - spent;
}

/// WorkBuddy and Qoder mark overlapping components as `aside` when publishing
/// an aggregate. An unknown primary window must not fall back to a known part.
List<Map> _creditWindows(Map? usage) {
  final credits = [
    for (final window in usage?['windows'] as List? ?? const [])
      if (window is Map && window['unit'] == 'credits') window,
  ];
  final primary = credits.where((w) => w['aside'] != true).toList();
  return primary.isNotEmpty ? primary : credits;
}

PluginCreditBalance? pluginCreditBalance(String provider, Map? usage) {
  if (usage == null) return null;
  // A native top-level balance is authoritative only when numeric and unitful.
  final balance = _number(usage['balance']);
  if (balance != null && usage['unit'] is String && usage['unit'] != '')
    return PluginCreditBalance(balance, usage['unit']);

  if (provider == 'loomy') {
    final windows = (usage['windows'] as List? ?? const []).whereType<Map>();
    final totals = windows.where(
      (w) =>
          w['aside'] != true &&
          w['unit'] == 'credits' &&
          {'积分合计', '可用积分'}.contains(w['name']),
    );
    if (totals.isNotEmpty) {
      return totals.length == 1 ? pluginWindowBalance(totals.single) : null;
    }
    // Earlier snapshots may only contain the two disjoint wallets.
    final wallets = <PluginCreditBalance>[];
    for (final name in ['每日赠送积分', '永久积分']) {
      final matches = windows.where((w) => w['name'] == name).toList();
      if (matches.length != 1) return null;
      final wallet = pluginWindowBalance(matches.single);
      if (wallet == null || wallet.unit != 'credits') return null;
      wallets.add(wallet);
    }
    return PluginCreditBalance(
      wallets[0].amount + wallets[1].amount,
      'credits',
    );
  }

  final windows = _creditWindows(usage);
  // Independent pools or model-specific quotas cannot imply an account total.
  return windows.length == 1 ? pluginWindowBalance(windows.single) : null;
}

/// Only giftOf sets runsOutAt in ZCode. dualUsage can still return Coding
/// Plan windows when giftOf fails, so queriedAt alone cannot clear gifts.
class ZcodeGiftExpiry {
  const ZcodeGiftExpiry._(this.observedAt, this.batches);
  static const unobserved = ZcodeGiftExpiry._(null, []);
  final DateTime? observedAt;
  final List<PluginCreditExpiry> batches;

  factory ZcodeGiftExpiry.fromUsage(Map? usage, DateTime? queriedAt) {
    final windows = usage?['windows'];
    if (windows is! List) return unobserved;
    final batches = <PluginCreditExpiry>[];
    var observed = false;
    for (final window in windows.whereType<Map>()) {
      final at = _windowExpiryTime(window);
      if (at == null) continue;
      observed = true;
      final batch = _expiry(
        at,
        window['runsOut'],
        window['unit'],
        dateOnly: _dateOnly(window),
      );
      if (batch != null) batches.add(batch);
    }
    return observed
        ? ZcodeGiftExpiry._(queriedAt, List.unmodifiable(batches))
        : unobserved;
  }

  bool usesReward(Map reward) {
    final buckets = reward['buckets'];
    if (buckets is! List) return false;
    final checkedAt = rewardObservedAt(reward);
    // Populated legacy journals have exact units but no comparable clock.
    if (checkedAt == null) return buckets.any((b) => b is Map);
    final native = observedAt;
    return native == null ||
        native.millisecondsSinceEpoch <= checkedAt.millisecondsSinceEpoch;
  }

  static DateTime? rewardObservedAt(Map reward) {
    final millis = reward['checkedAt'];
    return millis is int && millis > 0 && millis < 8640000000000000
        ? DateTime.fromMillisecondsSinceEpoch(millis)
        : null;
  }
}

DateTime? _windowExpiryTime(Map window) {
  final at = window['runsOutAt'];
  return at is String ? DateTime.tryParse(at) : null;
}

bool _dateOnly(Map window) =>
    window['runsOutAt'] is String &&
    RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(window['runsOutAt']);

PluginCreditExpiry? _expiry(
  DateTime? at,
  Object? amount,
  Object? unit, {
  bool dateOnly = false,
}) {
  final value = _number(amount);
  if (at == null || (value != null && value <= 0)) return null;
  return PluginCreditExpiry(
    at,
    value != null && unit is String && unit.isNotEmpty
        ? PluginCreditBalance(value, unit)
        : null,
    dateOnly: dateOnly,
    reportedUnit: unit is String ? unit : null,
  );
}

List<CreditExpiryEvidence> nativeCreditEvidence(Map? usage, DateTime observed) {
  final raw = usage?['creditBatches'];
  if (raw is! List) return const [];
  final batches = <String, CreditExpiryEvidence>{};
  for (final value in raw.whereType<Map>()) {
    final batch = CreditExpiryEvidence.read({
      ...value,
      'observedAt': observed.toUtc().toIso8601String(),
    });
    if (batch == null) continue;
    // An indistinguishable batch needs a provider ID before its quantity is reliable.
    batches.update(
      batch.key,
      (_) => CreditExpiryEvidence(
        batch.at,
        batch.unit,
        dateOnly: batch.dateOnly,
        sourceId: batch.sourceId,
        observedAt: observed,
      ),
      ifAbsent: () => batch,
    );
  }
  return batches.values.toList();
}

List<PluginCreditExpiry> pluginCreditExpiryBatches(
  Map? usage,
  Map reward,
  DateTime now, {
  String? provider,
  DateTime? queriedAt,
  ZcodeGiftExpiry? nativeGift,
}) {
  if (provider == 'zcode') {
    final gift = nativeGift ?? ZcodeGiftExpiry.fromUsage(usage, queriedAt);
    if (!gift.usesReward(reward)) {
      return gift.batches.where((b) => b.end.isAfter(now)).toList()
        ..sort((a, b) => a.at.compareTo(b.at));
    }
    // Both sources describe the same balance response. Neither exposes
    // entitlement IDs for a row join.
    usage = null;
  }
  final buckets = reward['buckets'];
  final detail = nativeCreditEvidence(usage, queriedAt ?? now);
  final detailedKeys = {for (final b in detail) (b.at, b.unit)};
  final rawWindows = usage?['windows'] as List? ?? const [];
  final windows = <({PluginCreditExpiry expiry, bool aside, Object? unit})>[];
  for (final window in rawWindows) {
    if (window is! Map) continue;
    final value = _expiry(
      _windowExpiryTime(window),
      window['runsOut'],
      window['unit'],
      dateOnly: _dateOnly(window),
    );
    if (value != null &&
        value.end.isAfter(now) &&
        !detailedKeys.contains((value.at.toLocal(), window['unit'])))
      windows.add((
        expiry: value,
        aside: window['aside'] == true,
        unit: window['unit'],
      ));
  }
  // An aggregate only supersedes a component at the same expiry and in the
  // same unit. Qoder's aside packages have expiry facts absent from its total;
  // those must survive, including packages denominated in tokens.
  final candidates = <PluginCreditExpiry>[
    for (final b in detail)
      if (b.end.isAfter(now) && b.unused == null && b.remaining != 0)
        PluginCreditExpiry(
          b.at,
          b.remaining == null
              ? null
              : PluginCreditBalance(b.remaining!, b.unit),
          dateOnly: b.dateOnly,
          reportedUnit: b.unit,
          sourceId: b.sourceId,
          issued: b.issued,
        ),
    for (final window in windows)
      if (!window.aside ||
          !windows.any(
            (other) =>
                !other.aside &&
                other.expiry.at.isAtSameMomentAs(window.expiry.at) &&
                window.unit is String &&
                other.unit == window.unit,
          ))
        window.expiry,
  ];
  for (final bucket in buckets is List ? buckets : const []) {
    if (bucket is! Map) continue;
    final seconds = _number(bucket['expiresAt']);
    final value = _expiry(
      seconds != null && seconds > 0 && seconds < 8640000000000
          ? DateTime.fromMillisecondsSinceEpoch(
              (seconds * 1000).round(),
              isUtc: true,
            )
          : null,
      bucket['remaining'],
      bucket['unit'],
    );
    if (value != null && value.at.isAfter(now)) candidates.add(value);
  }
  if (provider == 'zcode') {
    final observed = zcodeBuckets(reward).toList();
    for (final plan in zcodePlans(reward)) {
      final at = zcodeTime(plan['ends_at']);
      if (plan['status'] != 'active' || at == null || !at.isAfter(now))
        continue;
      final covered = observed.any((b) {
        if (b.instance != null) return b.instance == plan['user_plan_id'];
        if (b.planId != null) return b.planId == plan['plan_id'];
        // Older journals did not retain IDs. Never count an ambiguous bucket twice.
        return true;
      });
      if (!covered) candidates.add(PluginCreditExpiry(at, null));
    }
  }
  candidates.sort((a, b) => a.at.compareTo(b.at));
  return candidates;
}

PluginCreditExpiry? pluginCreditExpiry(
  Map? usage,
  Map reward,
  DateTime now, {
  String? provider,
  DateTime? queriedAt,
}) => nextPluginCreditExpiry(
  pluginCreditExpiryBatches(
    usage,
    reward,
    now,
    provider: provider,
    queriedAt: queriedAt,
  ),
);

/// The input is the chronological projection from pluginCreditExpiryBatches.
PluginCreditExpiry? nextPluginCreditExpiry(
  List<PluginCreditExpiry> candidates,
) {
  if (candidates.isEmpty) return null;
  final first = candidates.first;
  // Multiple independent model entitlements have no comparable account total.
  return PluginCreditExpiry(
    first.at,
    candidates.where((e) => e.at.isAtSameMomentAs(first.at)).length == 1
        ? first.amount
        : null,
  );
}
