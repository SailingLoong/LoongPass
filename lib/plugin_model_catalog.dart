import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'model_names.dart';
import 'plugin_accounts.dart';
import 'plugin_credit_balance.dart';
import 'plugin_model_quota.dart';

export 'plugin_model_quota.dart' show ModelQuotaStatus;

enum AutoRoutingPriority {
  modelOrder,
  creditExpiry;

  static const _key = 'autoPriority';

  static AutoRoutingPriority fromSettings(Map settings) =>
      values.asNameMap()[settings[_key]] ?? modelOrder;

  void saveTo(Map<String, dynamic> settings) => settings[_key] = name;
}

class PluginModelGrant {
  PluginModelGrant(this.account, this.token, this.enabled);
  final PluginAccount account;
  final String token;
  final bool enabled;
  bool get authorizationRequired =>
      !account.active || account.error == 'authorization_required';
  bool get available => enabled && !authorizationRequired;
}

class PluginModelBinding {
  PluginModelBinding(this.grant, this.native, this.enabled, this.quota);
  final PluginModelGrant grant;
  final Map<String, dynamic> native;
  final bool enabled;
  final PluginModelQuota quota;
  PluginAccount get account => grant.account;
  String get nativeId => native['id'];
  bool get generatesImages =>
      native['outputs'] is List &&
      (native['outputs'] as List).contains('image');
  bool get imageOnly =>
      generatesImages && !(native['outputs'] as List).contains('text');
  String get exportedId =>
      'accounts/${Uri.encodeComponent(account.key)}/${account.provider}/$nativeId';
  bool get giftOnly =>
      account.provider == 'zcode' && nativeId.toLowerCase().endsWith('-trial');
  ModelQuotaStatus get status => quota.status;
  PluginCreditExpiry? get expiry => quota.expiry;
  bool get available =>
      enabled &&
      grant.available &&
      !{ModelQuotaStatus.exhausted, ModelQuotaStatus.expired}.contains(status);

  int compareQuota(PluginModelBinding other) {
    if (available != other.available) return available ? -1 : 1;
    final left = expiry?.at, right = other.expiry?.at;
    if (left == null) return right == null ? 0 : 1;
    return right == null ? -1 : left.compareTo(right);
  }
}

class PluginModel {
  PluginModel(
    this.id,
    this.name,
    this.official,
    this.bindings, {
    this.published = false,
    this.previousPublishedIds = const {},
  });
  final String id;
  final String name;
  final bool official;
  final bool published;
  final Set<String> previousPublishedIds;
  final List<PluginModelBinding> bindings;
  String get groupId => groupIdFor(id);
  static String groupIdFor(String id) =>
      'loongpass-${sha256.convert(utf8.encode(id)).toString().substring(0, 20)}';
  bool get generatesImages => bindings.any((b) => b.generatesImages);
  String get publicId => 'group/$groupId';
  int get availableAccounts => bindings
      .where((b) => b.available)
      .map((b) => b.account.key)
      .toSet()
      .length;
  PluginModelBinding? get preferred =>
      published ? bindings.where((b) => b.available).firstOrNull : null;
  String get searchText =>
      '$id $name ${bindings.map((b) => '${b.nativeId} ${b.native['name'] ?? ''} ${b.account.label} ${b.account.provider}').join(' ')}'
          .toLowerCase();
}

bool supportedNativeModel(Map<String, dynamic> model) {
  final outputs = model['outputs'];
  return model['id'] is String &&
      (model['id'] as String).isNotEmpty &&
      (outputs is! List || !outputs.contains('video'));
}

/// Keep the original per-alias choices until explicitly overridden. The legacy
/// snapshot also covers accounts whose model catalog is temporarily unavailable.
Map<String, dynamic> upgradeModelRouting(Map settings) {
  final saved = Map<String, dynamic>.from(jsonDecode(jsonEncode(settings)));
  if (saved['version'] == 4) return saved;
  final Map<String, dynamic> routing;
  if (saved['version'] == 3) {
    routing = saved;
  } else if (saved['version'] == 2) {
    routing = {'legacy': saved.remove('legacy') ?? {}, 'previous': saved};
  } else {
    routing = {'legacy': saved};
  }
  // Oldest per-alias choices still govern the individual account bindings.
  // Later model-wide Auto preferences never represented explicit publication.
  for (final layer in [
    routing,
    if (routing['previous'] is Map) routing['previous'] as Map,
  ]) {
    layer.remove('models');
    layer.remove('defaultModelEnabled');
  }
  routing['version'] = 4;
  return routing;
}

List<PluginModel> pluginModelCatalog(
  List<PluginModelGrant> grants,
  Map settings,
  DateTime now,
) {
  settings = upgradeModelRouting(settings);
  final legacy = settings['legacy'] as Map? ?? {};
  final previous = settings['previous'] as Map? ?? {};
  final previousPublished = previous['published'] as Map? ?? {};
  final previousOrder = (previous['order'] as List?)?.whereType<String>();
  final legacyTargets = <String, Set<String>>{};
  final previousTargets = <String, Set<String>>{};
  final byId = <String, List<PluginModelBinding>>{};
  final names = <String, String>{};
  final official = <String>{};
  for (final grant in grants) {
    final usage = modelRoutingUsage(
      grant.account.provider,
      grant.account.models,
      grant.account.usage,
      now,
    );
    for (final native in grant.account.models.where(supportedNativeModel)) {
      final provider = grant.account.provider;
      final canonical = officialModelId(provider, native);
      final id = canonical ?? unverifiedModelId(native);
      final oldId = legacyModelId(provider, native);
      final previousId = previousModelId(provider, native);
      legacyTargets.putIfAbsent(oldId, () => {}).add(id);
      previousTargets.putIfAbsent(previousId, () => {}).add(id);
      final oldEnabled = legacy['models']?[oldId] != false;
      final accountEnabled =
          settings['accounts']?[id]?[grant.account.key] ??
          previous['accounts']?[previousId]?[grant.account.key] ??
          (legacy['accounts']?[oldId]?[grant.account.key] != false &&
              oldEnabled);
      if (canonical != null) official.add(id);
      names[id] = canonical ?? native['name'] as String? ?? native['id'];
      byId
          .putIfAbsent(id, () => [])
          .add(
            PluginModelBinding(
              grant,
              native,
              accountEnabled,
              pluginModelQuota(usage, native['id'], now),
            ),
          );
    }
  }
  // Live bindings disambiguate reused slots. For a missing source, a known
  // past model name can still carry the explicit group choice and order.
  for (final key in {
    ...?previousOrder,
    ...previousPublished.keys.whereType<String>(),
  }) {
    final id = officialModelIdForPreviousKey(key) ?? key;
    if (byId.containsKey(id)) previousTargets.putIfAbsent(key, () => {id});
  }
  final previousIds = <String, Set<String>>{};
  for (final entry in previousTargets.entries) {
    for (final id in entry.value) {
      previousIds.putIfAbsent(id, () => {}).add(entry.key);
    }
  }
  final order = <String>{
    ...?(settings['order'] as List?)?.whereType<String>(),
    ...?previousOrder?.expand((id) => previousTargets[id] ?? {id}),
    for (final id in (legacy['order'] as List? ?? const []).whereType<String>())
      ...legacyTargets[id] ?? {id},
  };
  final ids = {...order.where(byId.containsKey), ...byId.keys};
  return List.unmodifiable([
    for (final id in ids)
      PluginModel(
        id,
        names[id]!,
        official.contains(id),
        List.unmodifiable(
          byId[id]!..sort((a, b) {
            final quota = a.compareQuota(b);
            if (quota != 0) return quota;
            // Stable tie order avoids moving sessions or new requests between
            // equally expiring account identities when an unrelated row changes.
            final account = a.account.key.compareTo(b.account.key);
            return account != 0 ? account : a.nativeId.compareTo(b.nativeId);
          }),
        ),
        published:
            official.contains(id) &&
            (settings['published']?[id] ??
                previousIds[id]!.any((key) => previousPublished[key] == true)),
        previousPublishedIds: {
          for (final key in previousIds[id]!)
            if (key != id &&
                !byId.containsKey(key) &&
                previousTargets[key]!.length == 1 &&
                previousPublished[key] == true)
              key,
        },
      ),
  ]);
}
