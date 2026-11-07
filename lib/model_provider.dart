import 'dart:async';

enum ModelProtocol {
  messages('/messages'),
  chat('/chat/completions');

  const ModelProtocol(this.endpoint);
  final String endpoint;
}

class ModelAccount {
  final String id, label;
  final String? registrationId;
  const ModelAccount(this.id, this.label, {this.registrationId});
}

/// Public model facts reported by the platform, never credential material.
class ModelDefinition {
  final String id, name;
  final ModelProtocol protocol;
  final bool? tools;
  final int? contextWindow, outputLimit;
  const ModelDefinition(
    this.id, {
    required this.protocol,
    String? name,
    this.tools,
    this.contextWindow,
    this.outputLimit,
  }) : name = name ?? id;

  Map<String, Object?> toJson(String owner) => {
    'id': id,
    'object': 'model',
    'owned_by': owner,
    'name': name,
    'supported_endpoints': [protocol.endpoint],
    'native_endpoints': [protocol.endpoint],
    if (contextWindow != null) 'context_length': contextWindow,
    if (outputLimit != null) 'max_output_tokens': outputLimit,
    if (tools != null) 'supports_tool_calls': tools,
  };
}

class ModelCatalog {
  final String registrationId;
  final List<ModelDefinition> models;
  ModelCatalog({
    required this.registrationId,
    required List<ModelDefinition> models,
  }) : models = List.unmodifiable(models);
}

class ModelReply {
  final int status;
  final String contentType;
  final Stream<List<int>> body;
  final void Function()? cancel;
  const ModelReply(this.status, this.contentType, this.body, {this.cancel});
}

/// Credentials stay with each account owner. A registration identifies one
/// saved-account lifetime; ordinary token rotation does not change it.
abstract class ModelProvider {
  const ModelProvider();
  String get id;
  String get name;
  Set<ModelProtocol> get protocols;
  Future<List<ModelAccount>> accounts();
  Stream<void> get changes => const Stream.empty();
  Future<ModelCatalog> discoverModels(String accountId);
  Future<void> dispatch(
    String accountId,
    String registrationId,
    ModelProtocol protocol,
    Map<String, dynamic> body,
    Future<void> Function(ModelReply) consume, {
    required bool Function() isCurrent,
    required Future<void> cancelled,
  });
}

class ModelServiceFailure implements Exception {
  final String code;
  const ModelServiceFailure(this.code);
  @override
  String toString() => 'ModelServiceFailure($code)';
}

class ModelBinding {
  final String id, providerId, accountId, key;
  final String? registrationId, error;
  final bool enabled;
  final List<ModelDefinition> models;
  final DateTime? queriedAt;
  ModelBinding({
    required this.id,
    required this.providerId,
    required this.accountId,
    required this.key,
    required this.registrationId,
    required this.enabled,
    required List<ModelDefinition> models,
    this.error,
    this.queriedAt,
  }) : models = List.unmodifiable(models);
  @override
  String toString() => 'ModelBinding(redacted)';
}
