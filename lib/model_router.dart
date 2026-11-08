import 'dart:collection';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'model_provider.dart';

/// A catalog fact tied to one enabled saved-account connection.
class ModelTarget {
  final String bindingId, providerId;
  final ModelDefinition model;
  const ModelTarget({
    required this.bindingId,
    required this.providerId,
    required this.model,
  });
  String get id => '$bindingId/${model.id}';
}

class RoutedModel {
  final String id;
  final List<ModelTarget> targets;
  RoutedModel(this.id, List<ModelTarget> targets)
    : targets = List.unmodifiable(targets);
  List<String> get providerIds =>
      targets.map((t) => t.providerId).toSet().toList()..sort();
  int get platformCount => providerIds.length;
  int get accountCount => targets.map((t) => t.bindingId).toSet().length;

  Map<String, Object?> toJson() {
    int? minimum(int? Function(ModelDefinition) get) {
      final values = targets.map((t) => get(t.model)).toList();
      if (values.any((v) => v == null)) return null;
      return values.cast<int>().reduce((a, b) => a < b ? a : b);
    }

    return {
      ...ModelDefinition(
        id,
        protocol: ModelProtocol.messages,
        name: targets.first.model.canonicalId ?? targets.first.model.name,
        contextWindow: minimum((m) => m.contextWindow),
        outputLimit: minimum((m) => m.outputLimit),
        tools: targets.any((t) => t.model.tools == true)
            ? true
            : targets.any((t) => t.model.tools == null)
            ? null
            : false,
      ).toJson('loongpass'),
      'platforms': providerIds,
      'account_count': accountCount,
    };
  }
}

/// Never infer that a provider's "auto" or "fast" lane is a particular model.
/// Exact vendor model IDs retain version/date/variant tokens. This deliberately
/// under-merges undocumented aliases instead of sending a different model.
String routedModelId(String providerId, ModelDefinition model) {
  final id = (model.canonicalId ?? model.id).toLowerCase().replaceAll(
    RegExp(r'[ _]+'),
    '-',
  );
  return model.canonicalId == null ? '$providerId/$id' : id;
}

List<RoutedModel> groupModelTargets(Iterable<ModelTarget> targets) {
  final groups = <String, List<ModelTarget>>{};
  for (final target in targets) {
    groups
        .putIfAbsent(routedModelId(target.providerId, target.model), () => [])
        .add(target);
  }
  return [
    for (final id in groups.keys.toList()..sort()) RoutedModel(id, groups[id]!),
  ];
}

/// Owns session affinity and failure cooldowns; selecting never refreshes a
/// catalog, credential or balance and never dispatches/replays a request.
class ModelRouter {
  final DateTime Function() now;
  final int maxSessions;
  final _sessions = LinkedHashMap<String, (String, DateTime)>();
  final _cooldowns = <String, DateTime>{};
  int _next = 0;
  ModelRouter({DateTime Function()? now, this.maxSessions = 4096})
    : assert(maxSessions > 0),
      now = now ?? DateTime.now;
  int get sessionCount => _sessions.length;

  ModelTarget select(
    String modelId,
    List<ModelTarget> targets, {
    String? session,
  }) {
    final at = now();
    _sessions.removeWhere(
      (_, value) => at.difference(value.$2) > const Duration(hours: 6),
    );
    _cooldowns.removeWhere((_, until) => !until.isAfter(at));
    final available = targets
        .where((t) => !_cooldowns.containsKey(t.id))
        .toList();
    if (available.isEmpty)
      throw const ModelServiceFailure('model_temporarily_unavailable');
    final key = session == null || session.isEmpty
        ? null
        : sha256.convert(utf8.encode('$modelId\u0000$session')).toString();
    final previous = key == null ? null : _sessions.remove(key);
    final selected =
        available.where((t) => t.id == previous?.$1).firstOrNull ??
        available[_next++ % available.length];
    if (key != null) {
      _sessions[key] = (selected.id, at);
      while (_sessions.length > maxSessions) {
        _sessions.remove(_sessions.keys.first);
      }
    }
    return selected;
  }

  void failed(ModelTarget target) {
    _cooldowns[target.id] = now().add(const Duration(minutes: 1));
  }
}
