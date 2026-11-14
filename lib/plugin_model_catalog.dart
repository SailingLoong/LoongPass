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
  String get exportedId => '${account.provider}/$nativeId';
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
  String get publicId => 'loongpass/$id';
  int get availableAccounts => bindings
      .where((b) => b.available)
      .map((b) => b.account.key)
      .toSet()
      .length;
  PluginModelBinding? get preferred =>
      enabled ? bindings.where((b) => b.available).firstOrNull : null;
}

bool supportedNativeModel(Map<String, dynamic> model) {
  final outputs = model['outputs'];
  return model['id'] is String &&
      (model['id'] as String).isNotEmpty &&
      (outputs is! List || !outputs.contains('video'));
}

List<PluginModel> pluginModelCatalog(
  List<PluginModelGrant> grants,
  Map settings,
  DateTime now,
) {
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
      final id = canonical ?? '${grant.account.provider}/${native['id']}';
      if (canonical != null) official.add(id);
      names[id] = canonical ?? native['name'] as String? ?? native['id'];
      byId
          .putIfAbsent(id, () => [])
          .add(
            PluginModelBinding(
              grant,
              native,
              settings['accounts']?[id]?[grant.account.key] != false,
              pluginModelQuota(usage, native['id'], now),
            ),
          );
    }
  }
  final order = (settings['order'] as List? ?? const [])
      .whereType<String>()
      .toList();
  final ids = {...order.where(byId.containsKey), ...byId.keys};
  return List.unmodifiable([
    for (final id in ids)
      PluginModel(
        id,
        names[id]!,
        official.contains(id),
        settings['models']?[id] != false,
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
