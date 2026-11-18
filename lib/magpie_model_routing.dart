import 'plugin_model_catalog.dart';

/// The native configuration derived from the owner's model/expiry snapshot.
/// Only public choices become groups; account-scoped dependencies stay unlisted.
class MagpieModelRouting {
  MagpieModelRouting(List<PluginModel> models) {
    final auto = <String>[];
    for (final model in models.where((m) => m.routed)) {
      final members = <String>[];
      // The catalog already orders each model's accounts by availability and
      // exact remaining-credit expiry. Native order/session routing consumes it.
      for (final binding in model.bindings) {
        if (!binding.enabled || !binding.grant.available) continue;
        final id = binding.exportedId;
        members.add('loongpass/$id');
        exposed.add(id);
        accountModels.putIfAbsent(binding.account.key, () => {}).add(id);
      }
      if (members.isEmpty) continue;
      if (model.enabled) auto.addAll(members);
      if (model.published) {
        groups[model.groupId] = (name: model.name, members: members);
        // Existing clients can still name a published canonical chat alias;
        // it does not need a duplicate entry in the public native catalog.
        if (!model.generatesImages) {
          aliases['loongpass/${model.id}'] = model.publicId;
        }
      }
    }
    if (auto.isNotEmpty) {
      groups[autoGroupId] = (name: 'loongpass/auto', members: auto);
      aliases['loongpass/auto'] = 'group/$autoGroupId';
    }
  }

  static const autoGroupId = 'loongpass-auto';
  final groups = <String, ({String name, List<String> members})>{};
  final exposed = <String>{};
  final accountModels = <String, Set<String>>{};
  final aliases = <String, String>{};
}
