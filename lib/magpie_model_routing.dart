import 'package:flutter/foundation.dart' show mergeSort;

import 'plugin_model_catalog.dart';

typedef AutoRoute = ({PluginModel model, PluginModelBinding binding});

/// The native configuration derived from the owner's model/expiry snapshot.
/// Only public choices become groups; account-scoped dependencies stay unlisted.
class MagpieModelRouting {
  MagpieModelRouting(
    List<PluginModel> models, {
    this.priority = AutoRoutingPriority.modelOrder,
  }) {
    final auto = <AutoRoute>[];
    for (final model in models.where((m) => m.routed)) {
      final members = <String>[];
      // The catalog already orders each model's accounts by availability and
      // exact remaining-credit expiry. Native order/session routing consumes it.
      for (final binding in model.bindings) {
        if (!binding.enabled || !binding.grant.available) continue;
        final id = binding.exportedId;
        members.add('loongpass/$id');
        if (model.enabled) auto.add((model: model, binding: binding));
        exposed.add(id);
        accountModels.putIfAbsent(binding.account.key, () => {}).add(id);
      }
      if (members.isEmpty) continue;
      if (model.published) {
        groups[model.groupId] = (name: model.name, members: members);
        // Existing clients can still name a published canonical chat alias;
        // it does not need a duplicate entry in the public native catalog.
        if (!model.generatesImages) {
          aliases['loongpass/${model.id}'] = model.publicId;
          for (final id in model.previousPublishedIds) {
            aliases['loongpass/$id'] = model.publicId;
            aliases['group/${PluginModel.groupIdFor(id)}'] = model.publicId;
          }
        }
      }
    }
    if (auto.isNotEmpty) {
      if (priority == AutoRoutingPriority.creditExpiry) {
        // Stable sorting retains the saved model order for a shared deadline
        // and for candidates without a known spendable expiry.
        mergeSort(auto, compare: (a, b) => a.binding.compareQuota(b.binding));
      }
      groups[autoGroupId] = (
        name: 'loongpass/auto',
        members: [
          for (final route in auto) 'loongpass/${route.binding.exportedId}',
        ],
      );
      aliases['loongpass/auto'] = 'group/$autoGroupId';
    }
    preferred = auto.where((entry) => entry.binding.available).firstOrNull;
  }

  static const autoGroupId = 'loongpass-auto';
  final AutoRoutingPriority priority;
  late final AutoRoute? preferred;
  final groups = <String, ({String name, List<String> members})>{};
  final exposed = <String>{};
  final accountModels = <String, Set<String>>{};
  final aliases = <String, String>{};
}
