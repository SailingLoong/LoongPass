import 'plugin_credit_balance.dart';

enum ModelQuotaStatus { available, unknown, exhausted, expired }

String? _bareModelId(String value) {
  final at = value.lastIndexOf('@');
  return at > 0 ? value.substring(0, at) : null;
}

/// The native usage contract's model substring plus exact allow/deny lists.
bool modelWindowApplies(Map window, String model) {
  final id = model.toLowerCase();
  final word = window['model'];
  if (word is String && word.isNotEmpty && !id.contains(word.toLowerCase()))
    return false;
  final included = (window['models'] as List? ?? const [])
      .whereType<String>()
      .map((id) => id.toLowerCase());
  final excluded = (window['notModels'] as List? ?? const [])
      .whereType<String>()
      .map((id) => id.toLowerCase());
  // Matches pinned Magpie's idSet.has. A bare ID covers its context sizes,
  // while two explicitly sized IDs remain distinct. An allowlist wins.
  bool contains(Iterable<String> values) => values.any(
    (candidate) =>
        candidate == id ||
        candidate == _bareModelId(id) ||
        _bareModelId(candidate) == id,
  );
  return included.isNotEmpty ? contains(included) : !contains(excluded);
}

class PluginModelQuota {
  const PluginModelQuota(
    this.status,
    this.expiry,
    this.windows, {
    this.nextChangeAt,
    this.expiringWindows = const [],
  });
  final ModelQuotaStatus status;
  final PluginCreditExpiry? expiry;
  final List<Map<String, dynamic>> windows;
  final List<Map<String, dynamic>> expiringWindows;
  final DateTime? nextChangeAt;
}

PluginModelQuota pluginModelQuota(Map? usage, String nativeId, DateTime now) {
  final windows = [
    for (final window in usage?['windows'] as List? ?? const [])
      if (window is Map && modelWindowApplies(window, nativeId))
        Map<String, dynamic>.from(window),
  ];
  var status = ModelQuotaStatus.unknown;
  DateTime? nextChangeAt;
  final expiring = <Map<String, dynamic>>[];
  for (final window in windows) {
    final balance = pluginWindowRemaining(window);
    final at = DateTime.tryParse(window['runsOutAt'] as String? ?? '');
    final runsOut = window['runsOut'];
    final spent = window['used'];
    final reset = DateTime.tryParse(window['resetsAt'] as String? ?? '');
    for (final boundary in [at, reset]) {
      if (boundary != null &&
          boundary.isAfter(now) &&
          (nextChangeAt == null || boundary.isBefore(nextChangeAt))) {
        nextChangeAt = boundary;
      }
    }
    final resetElapsed = reset != null && !reset.isAfter(now);
    final empty = balance != null && balance <= 0;
    final expired =
        at != null &&
        !at.isAfter(now) &&
        balance != null &&
        runsOut is num &&
        runsOut.isFinite &&
        runsOut >= balance &&
        balance > 0;
    final exhausted =
        !resetElapsed && (empty || (spent is num && spent >= 100));
    if (window['aside'] != true) {
      if (expired) {
        status = ModelQuotaStatus.expired;
      } else if (exhausted) {
        status = ModelQuotaStatus.exhausted;
      } else if (!resetElapsed &&
          status == ModelQuotaStatus.unknown &&
          (balance != null || spent is num)) {
        status = ModelQuotaStatus.available;
      }
    }
    if (at != null &&
        at.isAfter(now) &&
        !empty &&
        !exhausted &&
        ((runsOut is num && runsOut.isFinite && runsOut > 0) ||
            (runsOut == null && balance != null && balance > 0))) {
      expiring.add(window);
    }
  }
  return PluginModelQuota(
    status,
    pluginCreditExpiry({'windows': expiring}, const {}, now),
    List.unmodifiable(windows),
    expiringWindows: List.unmodifiable(expiring),
    nextChangeAt: nextChangeAt,
  );
}

/// LoongPass enables the pinned ZCode plugin's freeFirst policy. Its native
/// usage hook lists gift windows under -Trial only, although the ordinary ID
/// can spend that gift too. Project that eligibility once for UI and bridge.
Map<String, dynamic>? modelRoutingUsage(
  String provider,
  List<Map<String, dynamic>> models,
  Map<String, dynamic>? usage,
  DateTime now,
) {
  if (usage == null || provider != 'zcode') return usage;
  final gifts = <String, String>{};
  final ids = models.map((m) => m['id'] as String).toList();
  for (final id in ids.where((id) => !id.toLowerCase().endsWith('-trial'))) {
    final trial = ids
        .where((other) => other.toLowerCase() == '${id.toLowerCase()}-trial')
        .firstOrNull;
    if (trial == null) continue;
    final quota = pluginModelQuota(usage, trial, now);
    if (quota.status == ModelQuotaStatus.available) gifts[id] = trial;
  }
  if (gifts.isEmpty) return usage;
  final windows = <Map<String, dynamic>>[];
  for (final raw in usage['windows'] as List? ?? const []) {
    if (raw is! Map) continue;
    final applicable = ids
        .where((id) => modelWindowApplies(raw, gifts[id] ?? id))
        .toList();
    if (applicable.isEmpty) continue;
    // Resolve the freeFirst projection to one native allowlist. Empty lists
    // mean unrestricted upstream, so windows with no applicable model are omitted.
    windows.add(
      {...raw, 'models': applicable}
        ..remove('model')
        ..remove('notModels'),
    );
  }
  return {...usage, 'windows': windows};
}
