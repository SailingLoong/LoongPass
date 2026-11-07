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
  QoderModelProvider(this.owner, {ModelTransport? transport})
    : transport = transport ?? ModelHttp() {
    if (owner.region != QoderRegion.cn)
      throw const ModelServiceFailure('unsupported_region');
  }
  @override
  String get id => 'qoder-cn';
  @override
  String get name => 'Qoder CN';
  @override
  Set<ModelProtocol> get protocols => {ModelProtocol.chat};
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
        int? positive(Object? n) => n is int && n > 0 ? n : null;
        return ModelCatalog(
          registrationId: registration,
          models: [
            for (final m in models)
              ModelDefinition(
                m['key'],
                protocol: ModelProtocol.chat,
                name: m['display_name'] is String ? m['display_name'] : null,
                contextWindow: positive(m['max_input_tokens']),
                outputLimit: positive(m['max_output_tokens']),
                tools: true,
              ),
          ],
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
  }) async {
    if (protocol != ModelProtocol.chat)
      throw const ModelServiceFailure('endpoint_not_supported');
    final saved = _models[accountId];
    final model = saved?.$2.where((m) => m['key'] == body['model']).firstOrNull;
    if (saved?.$1 != registrationId || model == null)
      throw const ModelServiceFailure('model_not_available');
    final wire = qoderEncodeBody(jsonEncode(qoderRequest(body, model)));
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
        consume: (reply) => consumeQoderReply(reply, body, consume),
      ),
      expectedRegistrationId: registrationId,
    );
  }
}
