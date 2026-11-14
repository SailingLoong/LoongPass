import 'plugin_credit_balance.dart';

enum ModelQuotaStatus { available, unknown, exhausted, expired }

String _modelKey(String value) => value.toLowerCase().split('@').first;

/// The native usage contract's model substring plus exact allow/deny lists.
bool modelWindowApplies(Map window, String model) {
  final id = _modelKey(model);
  final word = window['model'];
  if (word is String && word.isNotEmpty && !id.contains(word.toLowerCase()))
    return false;
  final included = (window['models'] as List? ?? const [])
      .whereType<String>()
      .map(_modelKey);
  final excluded = (window['notModels'] as List? ?? const [])
      .whereType<String>()
      .map(_modelKey);
  return (included.isEmpty || included.contains(id)) && !excluded.contains(id);
}

class PluginModelQuota {
  const PluginModelQuota(this.status, this.expiry, this.windows);
  final ModelQuotaStatus status;
  final PluginCreditExpiry? expiry;
  final List<Map<String, dynamic>> windows;
}

PluginModelQuota pluginModelQuota(Map? usage, String nativeId, DateTime now) {
  final windows = [
    for (final window in usage?['windows'] as List? ?? const [])
      if (window is Map && modelWindowApplies(window, nativeId))
        Map<String, dynamic>.from(window),
  ];
  var status = ModelQuotaStatus.unknown;
  final expiring = <Map<String, dynamic>>[];
  for (final window in windows) {
    final balance = pluginWindowRemaining(window);
    final at = DateTime.tryParse(window['runsOutAt'] as String? ?? '');
    final runsOut = window['runsOut'];
    final spent = window['used'];
    final reset = DateTime.tryParse(window['resetsAt'] as String? ?? '');
    final expired =
        at != null &&
        !at.isAfter(now) &&
        balance != null &&
        runsOut is num &&
        runsOut.isFinite &&
        runsOut >= balance &&
        balance > 0;
    final exhausted =
        (balance != null && balance <= 0) ||
        (spent is num && spent >= 100 && (reset == null || reset.isAfter(now)));
    if (window['aside'] != true) {
      if (expired) {
        status = ModelQuotaStatus.expired;
      } else if (exhausted) {
        status = ModelQuotaStatus.exhausted;
      } else if (status == ModelQuotaStatus.unknown &&
          (balance != null || spent is num)) {
        status = ModelQuotaStatus.available;
      }
    }
    if (at != null &&
        at.isAfter(now) &&
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
  return {
    ...usage,
    'windows': [
      for (final raw in usage['windows'] as List? ?? const [])
        if (raw is Map)
          {
            ...raw,
            'notModels': [
              ...raw['notModels'] as List? ?? const [],
              for (final entry in gifts.entries)
                if (modelWindowApplies(raw, entry.key) &&
                    !modelWindowApplies(raw, entry.value))
                  entry.key,
            ],
            if (raw['models'] is List && (raw['models'] as List).isNotEmpty)
              'models': [
                ...raw['models'] as List,
                for (final entry in gifts.entries)
                  if (modelWindowApplies(raw, entry.value)) entry.key,
              ],
          },
    ],
  };
}
