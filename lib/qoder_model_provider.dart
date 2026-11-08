import 'dart:async';
import 'dart:convert';
import 'model_provider.dart';
import 'model_http.dart';
import 'qoder_device_accounts.dart';
import 'qoder_protocol.dart';
import 'qoder_stream.dart';

class QoderModelProvider extends ModelProvider {
  final QoderDeviceAccounts owner;
  final ModelTransport transport;
  final _models = <String, (String, List<Map<String, dynamic>>)>{};
  final _tasks = <String, ({int began, int used, bool answered})>{};
  QoderModelProvider(this.owner, {ModelTransport? transport})
    : transport = transport ?? ModelHttp() {
    if (owner.region != QoderRegion.cn)
      throw const ModelServiceFailure('unsupported_region');
  }
  @override
  String get id => 'qoder-cn';
  @override
  String get name => 'Qoder CN';
  // COSY keys (qfmodel, kmodel_latest, ...) are routing handles. Only a
  // versioned public display name establishes which actual model they serve.
  static String? _canonicalId(Object? name) =>
      name is String &&
          RegExp(r'^[A-Za-z][A-Za-z0-9. _-]*$').hasMatch(name) &&
          RegExp(r'[0-9]').hasMatch(name)
      ? name
      : null;
  @override
  Set<ModelProtocol> get protocols => {ModelProtocol.chat};
  @override
  void validateRequest(ModelProtocol protocol, Map<String, dynamic> body) =>
      validateQoderRequest(body);
  @override
  Stream<void> get changes => owner.authorizationChanges;
  @override
  Future<List<ModelAccount>> accounts() async => [
    for (final a in await owner.accountViews())
      ModelAccount(a.uid, a.label, registrationId: a.registrationId),
  ];
  @override
  Future<ModelCatalog> discoverModels(String accountId) =>
      owner.withInferenceAuthorization(accountId, (
        token,
        machine,
        registration,
        current,
      ) async {
        final uri = Uri.parse('https://gateway.qoder.com.cn$qoderModelsPath');
        final listing = await modelJson(
          transport,
          uri,
          headers: qoderHeaders(
            uri,
            uid: accountId,
            token: token,
            machineId: machine,
          ),
          isCurrent: current,
        );
        final models = qoderModels(listing);
        if (models.isEmpty)
          throw const ModelServiceFailure('model_discovery_failed');
        _models[accountId] = (registration, models);
        ModelDefinition definition(Map<String, dynamic> model) {
          final spec = QoderModelSpec(model);
          return ModelDefinition(
            model['key'],
            canonicalId: _canonicalId(model['display_name']),
            protocol: ModelProtocol.chat,
            name: model['display_name'] is String
                ? model['display_name']
                : null,
            contextWindow: spec.contextWindow,
            outputLimit: spec.outputLimit,
            images: model['is_vl'] == true,
            reasoning: spec.reasoning,
            alwaysThinks: spec.alwaysThinks,
            reasoningEfforts: spec.supportedEfforts,
            defaultReasoningEffort: spec.defaultEffort,
            tools: true,
          );
        }

        return ModelCatalog(
          registrationId: registration,
          models: [for (final m in models) definition(m)],
        );
      });
  @override
  Future<void> dispatch(
    String accountId,
    String registrationId,
    ModelProtocol protocol,
    Map<String, dynamic> body,
    Future<void> Function(ModelReply) consume, {
    required bool Function() isCurrent,
    required Future<void> cancelled,
    ModelRequestContext? context,
  }) async {
    if (protocol != ModelProtocol.chat)
      throw const ModelServiceFailure('endpoint_not_supported');
    final saved = _models[accountId];
    final model = saved?.$2.where((m) => m['key'] == body['model']).firstOrNull;
    if (saved?.$1 != registrationId || model == null)
      throw const ModelServiceFailure('model_not_available');
    final identity =
        context ??
        ModelRequestContext.fromRequest(
          body,
        ).forAccount('$id/$accountId/$registrationId');
    final now = DateTime.now().millisecondsSinceEpoch;
    _tasks.removeWhere((_, task) => now - task.used > 7200000);
    final taskKey =
        '$accountId/$registrationId/${identity.sessionId}/${identity.turnId}';
    final task =
        _tasks.remove(taskKey) ?? (began: now, used: now, answered: false);
    _tasks[taskKey] = (began: task.began, used: now, answered: task.answered);
    while (_tasks.length > 512) {
      _tasks.remove(_tasks.keys.first);
    }
    final wire = qoderEncodeBody(
      jsonEncode(
        qoderRequest(
          body,
          model,
          context: identity,
          taskId: identity.turnId,
          taskBeganAt: task.began,
          taskAnswered: task.answered,
        ),
      ),
    );
    final uri = Uri.parse('https://gateway.qoder.com.cn$qoderChatPath');
    await owner.withInferenceAuthorization(
      accountId,
      (token, machine, registration, current) => transport.exchange(
        uri,
        method: 'POST',
        headers: {
          ...qoderHeaders(
            uri,
            uid: accountId,
            token: token,
            machineId: machine,
            body: wire,
            chat: true,
          ),
          'X-Model-Key': model['key'],
          'X-Model-Source': model['source'] ?? 'system',
        },
        body: wire,
        isCurrent: () => current() && isCurrent(),
        cancelled: cancelled,
        consume: (reply) async {
          var success = false;
          await consumeQoderReply(
            reply,
            body,
            (converted) async {
              await consume(converted);
              success = converted.status == 200;
            },
            onCredentialRejected: () => owner.rejectInferenceAuthorization(
              accountId,
              registration,
              token,
            ),
          );
          if (success && _tasks.containsKey(taskKey))
            _tasks[taskKey] = (
              began: task.began,
              used: DateTime.now().millisecondsSinceEpoch,
              answered: true,
            );
        },
      ),
      expectedRegistrationId: registrationId,
    );
  }
}
