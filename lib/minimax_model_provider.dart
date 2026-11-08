// MiniMax Code native Messages contract. Model configuration parsing follows
// magpie-community/plugins/packages/minimax/index.mjs (MIT), pinned in workspace upstream.
import 'dart:async';
import 'dart:convert';
import 'minimax_accounts.dart';
import 'model_provider.dart';
import 'model_http.dart';

class MiniMaxModelProvider extends ModelProvider {
  final MiniMaxAccounts owner;
  final String region;
  final ModelTransport transport;
  MiniMaxModelProvider(this.owner, this.region, {ModelTransport? transport})
    : transport = transport ?? ModelHttp() {
    if (!{'cn', 'global'}.contains(region))
      throw const ModelServiceFailure('unsupported_region');
  }
  @override
  String get id => 'minimax-$region';
  @override
  String get name => region == 'cn' ? 'MiniMax CN' : 'MiniMax';
  @override
  Set<ModelProtocol> get protocols => {ModelProtocol.messages};
  @override
  Stream<void> get changes => owner.changes;
  String get _host => region == 'cn' ? 'agent.minimax.cn' : 'agent.minimax.io';
  @override
  Future<List<ModelAccount>> accounts() async => [
    for (final a in await owner.list())
      if (a.region == region)
        ModelAccount(a.id, a.label, registrationId: a.registrationId),
  ];
  @override
  Future<ModelCatalog> discoverModels(
    String accountId,
  ) => owner.withInferenceAuthorization(accountId, (
    site,
    token,
    current,
    registration,
  ) async {
    if (site != region)
      throw const ModelServiceFailure('account_region_changed');
    final data = await modelJson(
      transport,
      Uri.https(_host, '/mavis/api/v1/models', {
        'region': region == 'cn' ? 'cn' : 'en',
        'buildEnv': 'prod',
      }),
      headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
      isCurrent: current,
    );
    final providers = data['providers'];
    final models = <ModelDefinition>[];
    if (providers is List)
      for (final p in providers) {
        if (p is! Map || p['providerId'] != 'minimax') continue;
        final config = p['config'];
        final raw = config is Map ? config['models'] : null;
        if (raw is! Map) continue;
        for (final entry in raw.entries) {
          final value = entry.value;
          if (entry.key is! String || value is! Map) continue;
          final limit = value['limit'];
          final modalities = value['modalities'];
          final input = modalities is Map ? modalities['input'] : null;
          final thinking = value['thinking'];
          final thinkingConfig = value['thinking_config'];
          final mode = thinkingConfig is Map ? thinkingConfig['mode'] : null;
          final rawEfforts =
              (thinking is Map
                  ? thinking['effortOptions'] ?? thinking['effort_options']
                  : null) ??
              value['effort_options'];
          final efforts = <String>[
            if (mode == 'switchable') 'none',
            if (rawEfforts is List)
              for (final effort in rawEfforts)
                if (effort is String &&
                    effort.isNotEmpty &&
                    effort != 'default' &&
                    effort != 'none')
                  effort,
          ];
          if (mode == 'switchable' && efforts.length == 1) efforts.add('high');
          final reasoning = switch (mode) {
            'forced_on' || 'switchable' => true,
            'forced_off' => false,
            _ =>
              value['reasoning'] is bool
                  ? value['reasoning'] as bool
                  : efforts.isNotEmpty
                  ? true
                  : null,
          };
          final defaultEffort = thinking is Map
              ? thinking['defaultEffort'] ?? thinking['default_effort']
              : null;
          int? positive(Object? n) => n is int && n > 0 ? n : null;
          models.add(
            ModelDefinition(
              entry.key,
              canonicalId: entry.key,
              protocol: ModelProtocol.messages,
              name: value['name'] is String ? value['name'] : null,
              contextWindow: limit is Map ? positive(limit['context']) : null,
              outputLimit: limit is Map ? positive(limit['output']) : null,
              tools: true,
              images: input is List
                  ? input.contains('image') || value['attachment'] == true
                  : value['attachment'] is bool
                  ? value['attachment'] as bool
                  : null,
              reasoning: reasoning,
              alwaysThinks: mode == 'forced_on'
                  ? true
                  : mode == 'switchable' || mode == 'forced_off'
                  ? false
                  : null,
              reasoningEfforts: List.unmodifiable(efforts.toSet()),
              defaultReasoningEffort:
                  defaultEffort is String && efforts.contains(defaultEffort)
                  ? defaultEffort
                  : null,
            ),
          );
        }
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
    ModelRequestContext? context,
  }) async {
    if (protocol != ModelProtocol.messages)
      throw const ModelServiceFailure('endpoint_not_supported');
    final requestContext =
        context ??
        ModelRequestContext.fromRequest(
          body,
          scope: '$id\u0000$accountId\u0000$registrationId',
        );
    (String, String)? rejected;
    try {
      await owner.withInferenceAuthorization(accountId, (
        site,
        token,
        current,
        registration,
      ) async {
        if (site != region)
          throw const ModelServiceFailure('account_region_changed');
        await transport.exchange(
          Uri.https(_host, '/mavis/api/v1/llm/v1/messages'),
          method: 'POST',
          body: body,
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/json, text/event-stream',
            'User-Agent': 'MiniMaxAgent',
            'anthropic-version': '2023-06-01',
            'x-mavis-session-id': requestContext.sessionId,
            'x-mavis-agent-id': requestContext.agentId,
            if (requestContext.anthropicBeta != null)
              'anthropic-beta': requestContext.anthropicBeta!,
            'x-mavis-timezone-offset':
                '${DateTime.now().timeZoneOffset.inSeconds}',
          },
          isCurrent: () => current() && isCurrent(),
          cancelled: cancelled,
          consume: (reply) async {
            if (reply.status == 401) rejected = (registration, token);
            await _consume(reply, consume);
          },
        );
      }, expectedRegistrationId: registrationId);
    } finally {
      if (rejected case (final registration, final token)) {
        await owner.rejectInferenceAuthorization(
          accountId,
          registration,
          token,
        );
      }
    }
  }

  static final _quota = RegExp(
    r'\b(?:balance|credits?|quota)\b|usage.{0,24}(?:limit|exhaust)|余额|积分|额度',
    caseSensitive: false,
  );

  static Future<void> _consume(
    ModelReply upstream,
    Future<void> Function(ModelReply) consume,
  ) async {
    if (upstream.status != 402 && upstream.status != 403) {
      await consume(upstream);
      return;
    }
    final bytes = <int>[];
    await for (final part in upstream.body) {
      if (bytes.length + part.length > 4 * 1024 * 1024)
        throw const ModelServiceFailure('invalid_response');
      bytes.addAll(part);
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    String message = text;
    try {
      final data = jsonDecode(text);
      if (data is Map) {
        final error = data['error'], base = data['base_resp'];
        final value =
            (error is Map ? error['message'] : error) ??
            data['message'] ??
            data['msg'] ??
            (base is Map ? base['status_msg'] : null);
        message = value is String ? value : '';
      }
    } catch (_) {}
    final exhausted = _quota.hasMatch(message);
    await consume(
      ModelReply(
        exhausted ? 429 : upstream.status,
        upstream.contentType,
        Stream.value(bytes),
        cancel: upstream.cancel,
        errorCode: exhausted ? 'quota_exhausted' : upstream.errorCode,
        retryAfterSeconds: upstream.retryAfterSeconds,
        credentialRejected: upstream.credentialRejected,
      ),
    );
  }
}
