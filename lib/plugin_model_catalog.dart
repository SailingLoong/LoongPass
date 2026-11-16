import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'model_names.dart';
import 'plugin_accounts.dart';
import 'plugin_credit_balance.dart';
import 'plugin_model_quota.dart';

export 'plugin_model_quota.dart' show ModelQuotaStatus;

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
  String get exportedId => generatesImages
      ? 'accounts/${Uri.encodeComponent(account.key)}/${account.provider}/$nativeId'
      : '${account.provider}/$nativeId';
  bool get giftOnly =>
      account.provider == 'zcode' && nativeId.toLowerCase().endsWith('-trial');
  ModelQuotaStatus get status => quota.status;
  PluginCreditExpiry? get expiry => quota.expiry;
  bool get available =>
      enabled &&
      grant.available &&
      !{ModelQuotaStatus.exhausted, ModelQuotaStatus.expired}.contains(status);
}

class PluginModel {
  PluginModel(this.id, this.name, this.official, this.enabled, this.bindings);
  final String id;
  final String name;
  final bool official;
  final bool enabled;
  final List<PluginModelBinding> bindings;
  String get groupId =>
      'loongpass-${sha256.convert(utf8.encode(id)).toString().substring(0, 20)}';
  bool get generatesImages => bindings.any((b) => b.generatesImages);
  String get publicId => generatesImages ? 'group/$groupId' : 'loongpass/$id';
  int get availableAccounts => bindings
      .where((b) => b.available)
      .map((b) => b.account.key)
      .toSet()
      .length;
  PluginModelBinding? get preferred =>
      enabled ? bindings.where((b) => b.available).firstOrNull : null;
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
  if (saved['version'] == 2) return saved;
  return {'version': 2, 'legacy': saved};
}

List<PluginModel> pluginModelCatalog(
  List<PluginModelGrant> grants,
  Map settings,
  DateTime now,
) {
  settings = upgradeModelRouting(settings);
  final legacy = settings['legacy'] as Map? ?? {};
  final legacyIds = <String, String>{};
  final legacyEnabled = <String>{};
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
      final canonical = officialModelId(grant.account.provider, native);
      final id = modelId(grant.account.provider, native);
      final oldId = legacyModelId(grant.account.provider, native);
      legacyIds[oldId] = id;
      final oldEnabled = legacy['models']?[oldId] != false;
      if (oldEnabled) legacyEnabled.add(id);
      final accountEnabled =
          settings['accounts']?[id]?[grant.account.key] ??
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
  final order =
      (settings['order'] as List? ?? legacy['order'] as List? ?? const [])
          .whereType<String>()
          .map((id) => legacyIds[id] ?? id)
          .toList();
  final ids = {...order.where(byId.containsKey), ...byId.keys};
  return List.unmodifiable([
    for (final id in ids)
      PluginModel(
        id,
        names[id]!,
        official.contains(id),
        settings['models']?[id] ??
            (settings['defaultModelEnabled'] != false &&
                legacyEnabled.contains(id)),
        List.unmodifiable(
          byId[id]!..sort((a, b) {
            if (a.available != b.available) return a.available ? -1 : 1;
            final left = a.expiry?.at, right = b.expiry?.at;
            if (left != null && right != null) {
              final compared = left.compareTo(right);
              if (compared != 0) return compared;
            } else if (left != right) {
              return left != null ? -1 : 1;
            }
            // Stable tie order avoids moving sessions or new requests between
            // equally expiring account identities when an unrelated row changes.
            final account = a.account.key.compareTo(b.account.key);
            return account != 0 ? account : a.nativeId.compareTo(b.nativeId);
          }),
        ),
      ),
  ]);
}
