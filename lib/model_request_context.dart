import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

/// Client identity and options carried alongside the model body. No credentials
/// or transcript are retained; vendors map this neutral context to their API.
class ModelRequestContext {
  final String sessionId, turnId, requestId, agentId;
  final bool hasSession;
  final String? anthropicBeta;
  const ModelRequestContext._(
    this.sessionId,
    this.turnId,
    this.requestId,
    this.agentId,
    this.hasSession,
    this.anthropicBeta,
  );

  factory ModelRequestContext.fromRequest(
    Map<String, dynamic> body, {
    String? session,
    String scope = '',
    String? anthropicBeta,
  }) {
    String? known = session == null || session.isEmpty || session == ':'
        ? null
        : session;
    String agent = 'main';
    if (known != null) {
      final separator = known.lastIndexOf(':');
      if (separator >= 0 && separator < known.length - 1) {
        agent = known.substring(separator + 1);
      }
    } else {
      final metadata = body['metadata'];
      final user = metadata is Map ? metadata['user_id'] : null;
      if (user is String) {
        try {
          final value = jsonDecode(user);
          if (value is Map &&
              value['session_id'] is String &&
              (value['session_id'] as String).isNotEmpty) {
            known = value['session_id'];
          }
        } catch (_) {}
      }
      final cacheKey = body['prompt_cache_key'];
      if (known == null && cacheKey is String && cacheKey.isNotEmpty) {
        known = cacheKey;
      }
    }
    final sid = known == null
        ? _randomUuid()
        : _namedUuid('session:$scope\u0000$known');
    final messages = body['messages'] is List
        ? body['messages'] as List
        : const [];
    String turn = '';
    for (var i = messages.length - 1; i >= 0; i--) {
      final message = messages[i];
      if (message is! Map || message['role'] != 'user') continue;
      final content = message['content'];
      if (content is List &&
          content.any((b) => b is Map && b['type'] == 'tool_result')) {
        continue;
      }
      var previous = i - 1;
      while (previous >= 0 &&
          messages[previous] is Map &&
          messages[previous]['role'] == 'system') {
        previous--;
      }
      if (previous >= 0 && messages[previous] is Map) {
        final before = messages[previous] as Map;
        final parts = before['content'];
        if (before['role'] == 'tool' ||
            before['role'] == 'assistant' &&
                (before['tool_calls'] is List &&
                        (before['tool_calls'] as List).isNotEmpty ||
                    parts is List &&
                        parts.any(
                          (b) => b is Map && b['type'] == 'tool_use',
                        ))) {
          continue;
        }
      }
      turn = jsonEncode([i, content]);
      break;
    }
    return ModelRequestContext._(
      sid,
      _namedUuid('turn:$sid\u0000$turn'),
      _randomUuid(),
      agent,
      known != null,
      anthropicBeta,
    );
  }

  ModelRequestContext forAccount(String scope) => ModelRequestContext._(
    _namedUuid('account-session:$scope\u0000$sessionId'),
    _namedUuid('account-turn:$scope\u0000$turnId'),
    requestId,
    agentId,
    hasSession,
    anthropicBeta,
  );
}

String _uuid(List<int> bytes, int version) {
  bytes[6] = (bytes[6] & 15) | version << 4;
  bytes[8] = (bytes[8] & 63) | 128;
  final h = bytes.map((n) => n.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

String _randomUuid() {
  final random = Random.secure();
  return _uuid(List.generate(16, (_) => random.nextInt(256)), 4);
}

// RFC 9562 UUIDv5, using the DNS namespace and an application-owned name.
String _namedUuid(String name) => _uuid(
  sha1
      .convert([
        0x6b,
        0xa7,
        0xb8,
        0x10,
        0x9d,
        0xad,
        0x11,
        0xd1,
        0x80,
        0xb4,
        0x00,
        0xc0,
        0x4f,
        0xd4,
        0x30,
        0xc8,
        ...utf8.encode('loongpass/$name'),
      ])
      .bytes
      .take(16)
      .toList(),
  5,
);
