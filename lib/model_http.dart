import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'model_provider.dart';

/// A single HTTP exchange. The account owner retains authorization and its lock
/// while consume reads the body. Never retries, follows redirects, or refreshes.
abstract class ModelTransport {
  Future<void> exchange(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const {},
    Object? body,
    required bool Function() isCurrent,
    Future<void>? cancelled,
    required Future<void> Function(ModelReply) consume,
  });
}

class ModelHttp implements ModelTransport {
  final HttpClient Function() _clientFactory;
  ModelHttp({HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? HttpClient.new;
  @override
  Future<void> exchange(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const {},
    Object? body,
    required bool Function() isCurrent,
    Future<void>? cancelled,
    required Future<void> Function(ModelReply) consume,
  }) async {
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 10);
    var finished = false, aborted = false;
    void cancel() {
      if (!finished) {
        aborted = true;
        client.close(force: true);
      }
    }

    if (cancelled != null) unawaited(cancelled.then((_) => cancel()));
    void check() {
      if (aborted || !isCurrent())
        throw const ModelServiceFailure('authorization_changed');
    }

    try {
      check();
      final request = await client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      headers.forEach(request.headers.set);
      if (body != null) {
        if (body is List<int>) {
          request.add(body);
        } else {
          request.headers.contentType = ContentType.json;
          // Preserve an explicit charset, required by some native APIs.
          if (headers.keys.any((k) => k.toLowerCase() == 'content-type')) {
            headers.forEach((k, v) {
              if (k.toLowerCase() == 'content-type') request.headers.set(k, v);
            });
          }
          request.write(body is String ? body : jsonEncode(body));
        }
      }
      check();
      final response = await request.close().timeout(
        const Duration(seconds: 60),
      );
      check();
      await consume(
        ModelReply(
          response.statusCode,
          response.headers.value(HttpHeaders.contentTypeHeader) ??
              'application/json',
          response.timeout(const Duration(minutes: 2)).map((chunk) {
            check();
            return chunk;
          }),
          cancel: cancel,
        ),
      );
    } finally {
      finished = true;
      client.close(force: true);
    }
  }
}

Future<Map<String, dynamic>> modelJson(
  ModelTransport transport,
  Uri uri, {
  String method = 'GET',
  Map<String, String> headers = const {},
  Object? body,
  required bool Function() isCurrent,
  int maxBytes = 4 * 1024 * 1024,
}) async {
  Map<String, dynamic>? result;
  await transport.exchange(
    uri,
    method: method,
    headers: headers,
    body: body,
    isCurrent: isCurrent,
    consume: (reply) async {
      if (reply.status != 200)
        throw const ModelServiceFailure('model_discovery_rejected');
      final bytes = <int>[];
      await for (final part in reply.body) {
        if (bytes.length + part.length > maxBytes)
          throw const ModelServiceFailure('invalid_model_catalog');
        bytes.addAll(part);
      }
      try {
        final value = jsonDecode(utf8.decode(bytes));
        if (value is! Map<String, dynamic>) throw const FormatException();
        result = value;
      } catch (_) {
        throw const ModelServiceFailure('invalid_model_catalog');
      }
    },
  );
  return result ?? (throw const ModelServiceFailure('invalid_model_catalog'));
}
