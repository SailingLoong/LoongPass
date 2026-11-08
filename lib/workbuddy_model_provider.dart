// WorkBuddy native mixed-protocol contract, adapted from
// magpie-community/plugins/packages/workbuddy/index.mjs (MIT), workspace pinned source.
import 'dart:async';
import 'workbuddy_accounts.dart';
import 'model_provider.dart';
import 'model_http.dart';
import 'workbuddy_protocol.dart';
import 'workbuddy_client_info.dart';
export 'workbuddy_client_info.dart';

class WorkBuddyModelProvider extends ModelProvider {
  final WorkBuddyAccounts owner;
  final ModelTransport transport;
  final Future<WorkBuddyClientInfo> Function() clientInfo;
  final _models = <String, (String, Map<String, WorkBuddyModelSpec>)>{};
  WorkBuddyModelProvider(
    this.owner, {
    required this.clientInfo,
    ModelTransport? transport,
  }) : transport = transport ?? ModelHttp();
  @override
  String get id => 'workbuddy-cn';
  @override
  String get name => 'WorkBuddy CN';
  @override
  Set<ModelProtocol> get protocols => ModelProtocol.values.toSet();
  @override
  Stream<void> get changes => owner.authorizationChanges;
  @override
  Future<List<ModelAccount>> accounts() async => [
    for (final a in owner.accounts)
      if (a.stableId != null && a.registrationId != null)
        ModelAccount(a.stableId!, a.uid!, registrationId: a.registrationId),
  ];
  Future<Map<String, String>> _headers(
    String domain,
    String uid,
    String token,
  ) async {
    final WorkBuddyClientInfo info;
    try {
      info = await clientInfo();
    } catch (_) {
      throw const ModelServiceFailure('client_info_unavailable');
    }
    if (!info.supported)
      throw const ModelServiceFailure('unsupported_client_version');
    final version = info.appVersion;
    return {
      'Authorization': 'Bearer $token',
      'X-User-Id': uid,
      'X-Domain': domain,
      'X-Product': 'SaaS',
      'X-IDE-Type': 'WorkBuddy',
      'X-IDE-Name': 'WorkBuddy',
      'X-IDE-Version': version,
      'User-Agent': info.userAgent,
      'X-Title': 'LoongPass',
      'X-Requested-With': 'XMLHttpRequest',
      'X-Agent-Type': 'main',
      'X-Agent-Runtime': 'local-agent',
      'X-Agent-Intent': 'craft',
      'X-Agent-Purpose': 'conversation',
      'Accept': 'application/json, text/event-stream',
    };
  }

  @override
  Future<ModelCatalog> discoverModels(String accountId) async {
    final a = (await accounts()).where((a) => a.id == accountId).firstOrNull;
    if (a == null) throw const ModelServiceFailure('account_unavailable');
    return owner.withInferenceAuthorization(accountId, a.registrationId!, (
      domain,
      uid,
      token,
      current,
    ) async {
      final response = await modelJson(
        transport,
        Uri.https('copilot.tencent.com', '/v3/config'),
        headers: await _headers(domain, uid, token),
        isCurrent: current,
      );
      if (response['code'] != null &&
          response['code'] != 0 &&
          response['code'] != '0')
        throw const ModelServiceFailure('model_discovery_rejected');
      final config = response['data'];
      final models = <ModelDefinition>[];
      final specs = <String, WorkBuddyModelSpec>{};
      if (config is Map &&
          config['agents'] is List &&
          config['models'] is List) {
        final definitions = config['models'] as List;
        for (final agent in config['agents']) {
          if (agent is! Map ||
              agent['name'] != 'cli' ||
              agent['models'] is! List)
            continue;
          for (final id in agent['models']) {
            if (id is! String) continue;
            final row = definitions
                .whereType<Map>()
                .where((d) => d['id'] == id)
                .firstOrNull;
            if (row == null) continue;
            final native = id.toLowerCase().startsWith('claude-');
            final spec = specs[id] = WorkBuddyModelSpec(row, messages: native);
            int? positive(Object? n) => n is int && n > 0 ? n : null;
            models.add(
              ModelDefinition(
                id,
                canonicalId: id == 'auto' ? null : id,
                protocol: native ? ModelProtocol.messages : ModelProtocol.chat,
                name: row['name'] is String ? row['name'] : null,
                contextWindow: positive(row['maxInputTokens']),
                outputLimit: positive(row['maxOutputTokens']),
                tools: row['supportsTools'] is bool
                    ? row['supportsTools']
                    : true,
                images: row['supportsImages'] == true,
                reasoning: spec.reasoning,
                alwaysThinks: spec.alwaysThinks,
                reasoningEfforts: spec.efforts,
                defaultReasoningEffort: spec.defaultEffort,
              ),
            );
          }
        }
      }
      if (models.isEmpty)
        throw const ModelServiceFailure('model_discovery_failed');
      _models[accountId] = (a.registrationId!, specs);
      return ModelCatalog(registrationId: a.registrationId!, models: models);
    });
  }

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
    final catalog = _models[accountId];
    final spec = catalog?.$1 == registrationId
        ? catalog?.$2[body['model']]
        : null;
    if (spec != null)
      ModelDefinition(
        body['model'],
        protocol: protocol,
        reasoning: spec.reasoning,
        alwaysThinks: spec.alwaysThinks,
      ).validateInput(body);
    await owner.withInferenceAuthorization(accountId, registrationId, (
      domain,
      uid,
      token,
      current,
    ) async {
      final chat = protocol == ModelProtocol.chat
          ? WorkBuddyChat(body, defaultEffort: spec?.defaultEffort)
          : null;
      final identity =
          context ??
          ModelRequestContext.fromRequest(
            body,
          ).forAccount('$id/$accountId/$registrationId');
      await transport.exchange(
        Uri.https(
          'copilot.tencent.com',
          protocol == ModelProtocol.messages
              ? '/v1/messages'
              : '/v2/chat/completions',
        ),
        method: 'POST',
        body: chat?.body ?? body,
        headers: {
          ...await _headers(domain, uid, token),
          if (identity.hasSession)
            'X-Conversation-ID': identity.sessionId.replaceAll('-', ''),
          'X-Conversation-Request-ID': identity.turnId.replaceAll('-', ''),
          'X-Conversation-Message-ID': identity.requestId.replaceAll('-', ''),
          'X-Request-ID': identity.requestId.replaceAll('-', ''),
          if (protocol == ModelProtocol.messages)
            'anthropic-version': '2023-06-01',
          if (protocol == ModelProtocol.messages &&
              context?.anthropicBeta != null)
            'anthropic-beta': context!.anthropicBeta!,
        },
        isCurrent: () => current() && isCurrent(),
        cancelled: cancelled,
        consume: (reply) async {
          try {
            final normalized = await workBuddyFailure(reply);
            await consume(
              chat == null ? normalized : await chat.restoreReply(normalized),
            );
          } finally {
            if (reply.credentialRejected)
              await owner.rejectInferenceAuthorization(
                accountId,
                registrationId,
                token,
              );
          }
        },
      );
    });
  }
}
