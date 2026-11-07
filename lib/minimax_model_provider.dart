// MiniMax Code native Messages contract. Model configuration parsing follows
// magpie-community/providers/minimax/index.mjs (MIT), pinned in workspace upstream.
import 'dart:async';
import 'dart:math';
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
          int? positive(Object? n) => n is int && n > 0 ? n : null;
          models.add(
            ModelDefinition(
              entry.key,
              protocol: ModelProtocol.messages,
              name: value['name'] is String ? value['name'] : null,
              contextWindow: limit is Map ? positive(limit['context']) : null,
              outputLimit: limit is Map ? positive(limit['output']) : null,
            ),
          );
        }
      }
    if (models.isEmpty)
      throw const ModelServiceFailure('model_discovery_failed');
    return ModelCatalog(registrationId: registration, models: models);
  });
  static String _session() {
    final r = Random.secure();
    final b = List.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
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
  }) {
    if (protocol != ModelProtocol.messages)
      throw const ModelServiceFailure('endpoint_not_supported');
    return owner.withInferenceAuthorization(accountId, (
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
          'x-mavis-session-id': _session(),
          'x-mavis-agent-id': 'main',
          'x-mavis-timezone-offset':
              '${DateTime.now().timeZoneOffset.inSeconds}',
        },
        isCurrent: () => current() && isCurrent(),
        cancelled: cancelled,
        consume: consume,
      );
    }, expectedRegistrationId: registrationId);
  }
}
