import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'reward_provider.dart';

/// Bounded control-plane requests. Each adapter supplies its official hosts;
/// credentials are never forwarded through redirects or surfaced in errors.
class RewardHttp implements RewardTransport {
  RewardHttp(Set<String> hosts) : hosts = Set.unmodifiable(hosts);
  final Set<String> hosts;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  bool _closed = false;
  @override
  Future<RewardReply> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Object? body,
  }) async {
    if (url.scheme != 'https' ||
        !hosts.contains(url.host) ||
        url.port != 443 ||
        url.userInfo.isNotEmpty ||
        url.hasFragment) {
      throw const RewardFailure('invalid_endpoint');
    }
    if (_closed || !{'GET', 'POST'}.contains(method))
      throw const RewardFailure('invalid_request');
    HttpClientRequest? request;
    var expired = false;
    final deadline = Timer(const Duration(seconds: 30), () {
      expired = true;
      request?.abort();
    });
    try {
      request = await _client
          .openUrl(method, url)
          .timeout(const Duration(seconds: 30));
      if (expired || _closed) {
        request.abort();
        throw const RewardFailure('network_unavailable');
      }
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        final bytes = utf8.encode(body is String ? body : jsonEncode(body));
        if (bytes.length > 2 * 1024 * 1024)
          throw const RewardFailure('invalid_request');
        if (!headers.keys.any((key) => key.toLowerCase() == 'content-type')) {
          request.headers.contentType = ContentType.json;
        }
        request.add(bytes);
      }
      final response = await request.close();
      if (response.statusCode >= 300 && response.statusCode < 400)
        throw const RewardFailure('redirect_rejected');
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 2 * 1024 * 1024) {
          request.abort();
          throw const RewardFailure('invalid_response');
        }
        bytes.addAll(chunk);
      }
      final payload = jsonDecode(utf8.decode(bytes));
      if (payload is! Map<String, dynamic>)
        throw const RewardFailure('invalid_response');
      return RewardReply(response.statusCode, payload);
    } on RewardFailure {
      rethrow;
    } catch (_) {
      throw const RewardFailure('network_unavailable');
    } finally {
      deadline.cancel();
    }
  }

  void close() {
    _closed = true;
    _client.close(force: true);
  }
}
