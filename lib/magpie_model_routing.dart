import 'package:flutter/foundation.dart' show mergeSort;

import 'plugin_model_catalog.dart';

typedef AutoRoute = ({PluginModel model, PluginModelBinding binding});

/// The user's publications and their account-scoped native dependencies.
class MagpieModelRouting {
  MagpieModelRouting(
    List<PluginModel> models, {
    this.priority = AutoRoutingPriority.modelOrder,
  }) {
    for (final model in models.where((m) => m.published)) {
      final members = <String>[];
      for (final binding in model.bindings) {
        if (!binding.enabled || !binding.grant.available) continue;
        final id = binding.exportedId;
        members.add('loongpass/$id');
        exposed.add(id);
        accountModels.putIfAbsent(binding.account.key, () => {}).add(id);
      }
      if (members.isEmpty) continue;
      _publicModels[model.publicId] = model;
      groups[model.groupId] = (name: model.name, members: members);
      if (!model.generatesImages) {
        aliases['loongpass/${model.id}'] = model.publicId;
        for (final id in model.previousPublishedIds) {
          aliases['loongpass/$id'] = model.publicId;
          aliases['group/${PluginModel.groupIdFor(id)}'] = model.publicId;
        }
      }
    }
    usePublicOrder(_publicModels.keys);
  }

  static const autoGroupId = 'loongpass-auto';
  final AutoRoutingPriority priority;
  AutoRoute? preferred;
  late List<PluginModel> candidates;
  final _publicModels = <String, PluginModel>{};
  final groups = <String, ({String name, List<String> members})>{};
  final exposed = <String>{};
  final accountModels = <String, Set<String>>{};
  final availableAccounts = <String>{};
  final aliases = <String, String>{};

  Iterable<String> get publicIds => _publicModels.keys;

  /// Uses the same group IDs and sequence as Magpie's public catalog. Only
  /// expiry-first needs individual account routes to compare spendable credits.
  void usePublicOrder(Iterable<String> publicIds) {
    candidates = List.unmodifiable([
      for (final id in publicIds)
        if (_publicModels[id] case final model?) model,
    ]);
    final routes = [
      for (final model in candidates)
        for (final binding in model.bindings)
          if (binding.enabled && binding.grant.available)
            (model: model, binding: binding),
    ];
    if (priority == AutoRoutingPriority.creditExpiry) {
      mergeSort(routes, compare: (a, b) => a.binding.compareQuota(b.binding));
    }
    final available = routes.where((entry) => entry.binding.available);
    availableAccounts
      ..clear()
      ..addAll(available.map((entry) => entry.binding.account.key));
    preferred = available.firstOrNull;
    if (routes.isEmpty) {
      groups.remove(autoGroupId);
      aliases.remove('loongpass/auto');
    } else {
      groups[autoGroupId] = (
        name: 'loongpass/auto',
        members: priority == AutoRoutingPriority.modelOrder
            ? [for (final model in candidates) model.publicId]
            : [
                for (final route in routes)
                  'loongpass/${route.binding.exportedId}',
              ],
      );
      aliases['loongpass/auto'] = 'group/$autoGroupId';
    }
  }
}
