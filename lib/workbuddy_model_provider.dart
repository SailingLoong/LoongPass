// WorkBuddy native mixed-protocol contract, adapted from
// magpie-community/plugins/packages/workbuddy/index.mjs (MIT), workspace pinned source.
import 'dart:async';
import 'workbuddy_accounts.dart';
import 'model_provider.dart';
import 'model_http.dart';

class WorkBuddyModelProvider extends ModelProvider {
  final WorkBuddyAccounts owner;
  final ModelTransport transport;
  final Future<String> Function() clientVersion;
  WorkBuddyModelProvider(
    this.owner, {
    required this.clientVersion,
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
    final String raw;
    try {
      raw = await clientVersion();
    } catch (_) {
      throw const ModelServiceFailure('client_version_unavailable');
    }
    if (!RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?$').hasMatch(raw))
      throw const ModelServiceFailure('client_version_unavailable');
    final parts = raw.split('.').take(3).toList(),
        numbers = raw.split('.').take(3).map(int.parse).toList();
    if (numbers[0] < 5 ||
        numbers[0] == 5 &&
            (numbers[1] < 9 || numbers[1] == 9 && numbers[2] < 3))
      throw const ModelServiceFailure('unsupported_client_version');
    final version = parts.join('.');
    return {
      'Authorization': 'Bearer $token',
      'X-User-Id': uid,
      'X-Domain': domain,
      'X-Product': 'SaaS',
      'X-IDE-Type': 'WorkBuddy',
      'X-IDE-Name': 'WorkBuddy',
      'X-IDE-Version': version,
      'User-Agent': 'WorkBuddy/$version LoongPass',
      'X-Title': 'LoongPass',
      'X-Requested-With': 'XMLHttpRequest',
      'X-Agent-Type': 'main',
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
      if (config is Map &&
          config['agents'] is List &&
          config['models'] is List) {
        final definitions = config['models'] as List;
        for (final agent in config['agents']) {
          if (agent is! Map ||
              agent['name'] != 'craft' ||
              agent['models'] is! List)
            continue;
          for (final id in agent['models']) {
            if (id is! String) continue;
            final row = definitions
                .whereType<Map>()
                .where((d) => d['id'] == id)
                .firstOrNull;
            if (row == null) continue;
            int? positive(Object? n) => n is int && n > 0 ? n : null;
            models.add(
              ModelDefinition(
                id,
                canonicalId: id == 'auto' ? null : id,
                protocol: id.toLowerCase().startsWith('claude-')
                    ? ModelProtocol.messages
                    : ModelProtocol.chat,
                name: row['name'] is String ? row['name'] : null,
                contextWindow: positive(row['maxInputTokens']),
                outputLimit: positive(row['maxOutputTokens']),
                tools: row['supportsTools'] is bool
                    ? row['supportsTools']
                    : null,
              ),
            );
          }
        }
      }
      if (models.isEmpty)
        throw const ModelServiceFailure('model_discovery_failed');
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
  }) => owner.withInferenceAuthorization(
    accountId,
    registrationId,
    (domain, uid, token, current) async => transport.exchange(
      Uri.https(
        'copilot.tencent.com',
        protocol == ModelProtocol.messages
            ? '/v1/messages'
            : '/v2/chat/completions',
      ),
      method: 'POST',
      body: body,
      headers: {
        ...await _headers(domain, uid, token),
        if (protocol == ModelProtocol.messages)
          'anthropic-version': '2023-06-01',
      },
      isCurrent: () => current() && isCurrent(),
      cancelled: cancelled,
      consume: consume,
    ),
  );
}
