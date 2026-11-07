// Native Messages wire contract from MiniMax Code, also documented in
// SailingLoong/LoongPort minimax_code/inference.rs (MIT). No protocol conversion.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'minimax_accounts.dart';
import 'model_service.dart';

class MiniMaxModelProvider implements ModelProvider {
  final MiniMaxAccounts owner;
  final String region;
  final HttpClient Function() _clientFactory;
  MiniMaxModelProvider(
    this.owner,
    this.region, {
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new {
    if (!{'cn', 'global'}.contains(region))
      throw const ModelServiceFailure('unsupported_region');
  }
  @override
  String get id => 'minimax-$region';
  @override
  String get name => region == 'cn' ? 'MiniMax CN' : 'MiniMax';

  @override
  Future<List<ModelAccount>> accounts() async => [
    for (final account in await owner.list())
      if (account.region == region) ModelAccount(account.id, account.label),
  ];

  static String _session() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final h = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  @override
  Future<void> dispatch(
    String accountId,
    Map<String, dynamic> body,
    Future<void> Function(ModelReply) consume,
  ) => owner.withInferenceAuthorization(accountId, (
    accountRegion,
    token,
    isCurrent,
  ) async {
    if (accountRegion != region)
      throw const ModelServiceFailure('account_region_changed');
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      if (!isCurrent())
        throw const ModelServiceFailure('authorization_changed');
      final request = await client.postUrl(
        Uri.https(
          region == 'cn' ? 'agent.minimax.cn' : 'agent.minimax.io',
          '/mavis/api/v1/llm/v1/messages',
        ),
      );
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.contentType = ContentType.json;
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/json, text/event-stream',
      );
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.headers.set(HttpHeaders.userAgentHeader, 'MiniMaxAgent');
      request.headers.set('anthropic-version', '2023-06-01');
      request.headers.set('x-mavis-session-id', _session());
      request.headers.set('x-mavis-agent-id', 'main');
      request.headers.set(
        'x-mavis-timezone-offset',
        '${DateTime.now().timeZoneOffset.inSeconds}',
      );
      if (!isCurrent()) {
        request.abort();
        throw const ModelServiceFailure('authorization_changed');
      }
      request.write(jsonEncode(body));
      final response = await request.close().timeout(
        const Duration(seconds: 60),
      );
      await consume(
        ModelReply(
          response.statusCode,
          response.headers.contentType?.toString() ?? 'application/json',
          response.timeout(const Duration(minutes: 2)).map((part) {
            if (!isCurrent())
              throw const ModelServiceFailure('authorization_changed');
            return part;
          }),
          cancel: () => client.close(force: true),
        ),
      );
    } finally {
      client.close(force: true);
    }
  });
}
