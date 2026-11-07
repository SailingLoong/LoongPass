// Native gateway contract: magpie-community/plugins/packages/loomy/index.mjs (MIT),
// pinned by the workspace. No guessed fallback catalog or session lifetime.
import 'dart:async';
import 'model_provider.dart';
import 'model_http.dart';
import 'rewards/reward_accounts.dart';
import 'rewards/reward_provider.dart';

class LoomyModelProvider extends ModelProvider {
  final RewardAccounts owner;
  final ModelTransport transport;
  LoomyModelProvider(this.owner, {ModelTransport? transport})
    : transport = transport ?? ModelHttp();
  @override
  String get id => 'loomy';
  @override
  String get name => 'Loomy';
  @override
  Set<ModelProtocol> get protocols => {ModelProtocol.chat};
  @override
  Stream<void> get changes =>
      owner.authorizationChanges.where((p) => p == id).map((_) {});
  @override
  Future<List<ModelAccount>> accounts() async => [
    for (final a in owner.accountsFor(id))
      ModelAccount(a.identity, a.label, registrationId: a.registrationId),
  ];
  Map<String, String> _headers(RewardSession session) {
    final token = session.credentials['access_token'];
    if (session.credentials['userid'] != session.identity ||
        token is! String ||
        token.isEmpty)
      throw const ModelServiceFailure('account_unavailable');
    return {
      'token': token,
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json;charset=utf-8',
    };
  }

  @override
  Future<ModelCatalog> discoverModels(String accountId) =>
      owner.withInferenceAuthorization(id, accountId, (
        session,
        current,
        registration,
      ) async {
        final response = await modelJson(
          transport,
          Uri.https('loomyad.xunfei.cn', '/api/v1/models'),
          headers: _headers(session),
          isCurrent: current,
        );
        if (response['code'] != null && response['code'] != '000000')
          throw const ModelServiceFailure('model_discovery_rejected');
        final raw = response['data'];
        final models = <ModelDefinition>[];
        int? integer(Object? n) {
          final v = n is num ? n.toInt() : int.tryParse('$n');
          return v != null && v > 0 ? v : null;
        }

        if (raw is List)
          for (final row in raw) {
            if (row is! Map || row['id'] is! String) continue;
            final limit = row['limit'];
            final caps = row['capabilities'];
            // This gateway's image-generation entries are not Chat models.
            if (caps is Map &&
                (caps['image_generation'] == true || caps['chat'] == false))
              continue;
            models.add(
              ModelDefinition(
                row['id'],
                protocol: ModelProtocol.chat,
                name: row['name'] is String
                    ? row['name']
                    : row['display_name'] is String
                    ? row['display_name']
                    : null,
                tools: caps is Map && caps['function_calling'] is bool
                    ? caps['function_calling']
                    : null,
                contextWindow: integer(
                  row['context_window'] ??
                      row['context_length'] ??
                      (limit is Map ? limit['context'] : null),
                ),
                outputLimit: integer(
                  row['max_tokens'] ?? (limit is Map ? limit['output'] : null),
                ),
              ),
            );
          }
        if (models.isEmpty)
          throw const ModelServiceFailure('model_discovery_failed');
        return ModelCatalog(registrationId: registration, models: models);
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
  }) {
    if (protocol != ModelProtocol.chat)
      throw const ModelServiceFailure('endpoint_not_supported');
    return owner.withInferenceAuthorization(
      id,
      accountId,
      (session, current, registration) => transport.exchange(
        Uri.https('loomyad.xunfei.cn', '/api/v1/chat/completions'),
        method: 'POST',
        headers: {..._headers(session), 'Accept': 'text/event-stream'},
        body: body,
        isCurrent: () => current() && isCurrent(),
        cancelled: cancelled,
        consume: consume,
      ),
      expectedRegistrationId: registrationId,
    );
  }
}
