// Adapted from magpie-community/plugins packages/qoder 0.2.63 (MIT), whose
// COSY protocol derives from CLIProxyAPI. See MODEL-ADAPTERS-LICENSE.txt and
// QODER-CLIPROXYAPI-LICENSE.txt. Cryptography uses Pointy Castle primitives.
import 'dart:convert';
import 'dart:io';
import 'dart:ffi' show Abi;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';
import 'account_registration.dart';
import 'model_provider.dart';

const qoderCosyVersion =
    '1.1.69'; // The vendor worker wire protocol, not a CLI version.
const qoderChatPath =
    '/algo/api/v2/service/pro/sse/agent_chat_generation?FetchKeys=llm_model_result&AgentId=agent_common&Encode=1';
const qoderModelsPath = '/algo/api/v2/model/list?Encode=1';
String qoderUuid() {
  final h = newAccountRegistrationId();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-4${h.substring(13, 16)}-8${h.substring(17, 20)}-${h.substring(20)}';
}

String qoderEncodeBody(String text) {
  const alphabet =
      '_doRTgHZBKcGVjlvpC,@aFSx#DPuNJme&i*MzLOEn)sUrthbf%Y^w.(kIQyXqWA!';
  const standard =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final s = base64Encode(utf8.encode(text))
      .split('')
      .map((c) => c == '=' ? '\$' : alphabet[standard.indexOf(c)])
      .join();
  final n = s.length ~/ 3;
  return n == 0
      ? s
      : s.substring(s.length - n) +
            s.substring(n, s.length - n) +
            s.substring(0, n);
}

Map<String, String> qoderHeaders(
  Uri uri, {
  required String uid,
  required String token,
  required String machineId,
  String body = '',
  bool chat = false,
}) {
  final key = Uint8List.fromList(
    utf8.encode(newAccountRegistrationId().substring(0, 16)),
  );
  final aes = PaddedBlockCipher('AES/CBC/PKCS7')
    ..init(
      true,
      PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
        ParametersWithIV(KeyParameter(key), key),
        null,
      ),
    );
  final info = base64Encode(
    aes.process(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'uid': uid,
            'aid': '',
            'name': '',
            'email': '',
            'security_oauth_token': token,
          }),
        ),
      ),
    ),
  );
  // Qoder's published client RSA public key, modulus extracted from its SPKI.
  final public = RSAPublicKey(
    BigInt.parse(
      'c0f22307e5cd362e296bb04470f6de8fbf935ce24e8fcf511a0e2701329769c4a76e499bb938036a52af1eaf818cf79a2600620e3ce87e371d2ca6d85803606a1b3fa5e874643c9ed2db7e85673ef7227fca56e2e7c08f0927609bb896a9f24be1782099a66016a5bfdc3f1ff756bfc9e88d7b5dc5be30bf45a0223a00ebcecf',
      radix: 16,
    ),
    BigInt.from(65537),
  );
  final rsa = PKCS1Encoding(RSAEngine())
    ..init(true, PublicKeyParameter<RSAPublicKey>(public));
  final wrapped = base64Encode(rsa.process(key));
  final payload = base64Encode(
    utf8.encode(
      jsonEncode({
        'version': 'v1',
        'requestId': qoderUuid(),
        'info': info,
        'cosyVersion': qoderCosyVersion,
        'ideVersion': '',
      }),
    ),
  );
  final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final path = uri.path.startsWith('/algo') ? uri.path.substring(5) : uri.path;
  final signature = md5.convert(
    utf8.encode('$payload\n$wrapped\n$timestamp\n$body\n$path'),
  );
  final arch = Abi.current().toString().toLowerCase().contains('arm64')
      ? 'aarch64'
      : 'x86_64';
  final platform = Platform.isMacOS
      ? 'darwin'
      : Platform.isWindows
      ? 'win32'
      : Platform.operatingSystem;
  return {
    'Accept': chat ? 'text/event-stream' : 'application/json',
    'Content-Type': 'application/json',
    'Authorization': 'Bearer COSY.$payload.$signature',
    'Cosy-Business-Product': 'app',
    'Cosy-Business-Type': 'agent',
    if (!chat) 'Cosy-ClientIp': machineId,
    'Cosy-ClientType': '10',
    'Cosy-Data-Policy': 'disagree',
    'Cosy-Date': '$timestamp',
    'Cosy-Key': wrapped,
    'Cosy-MachineId': machineId,
    if (!chat) 'Cosy-MachineToken': machineId,
    if (!chat) 'Cosy-MachineType': '5',
    'Cosy-MachineOS': '${arch}_$platform',
    'Cosy-Scene': 'app',
    'Cosy-User': uid,
    'Cosy-Version': qoderCosyVersion,
    'Login-Version': 'v2',
    if (chat) 'Cache-Control': 'no-cache',
  };
}

List<Map<String, dynamic>> qoderModels(Map<String, dynamic> listing) {
  final models = <String, Map<String, dynamic>>{};
  for (final scene in ['app', 'chat']) {
    final rows = listing[scene];
    if (rows is! List) continue;
    for (final row in rows) {
      if (row is! Map<String, dynamic> || row['key'] is! String) continue;
      final key = row['key'] as String;
      if (key.isEmpty || {'auto', 'default'}.contains(key)) continue;
      models.putIfAbsent(key, () => row);
    }
  }
  return models.values.where((m) => m['enable'] == true).toList();
}

String _text(Object? content) {
  if (content is String) return content;
  if (content is List)
    return content
        .whereType<Map>()
        .where((b) => b['type'] == 'text')
        .map((b) => b['text'] ?? '')
        .join('');
  return '';
}

List<Map<String, dynamic>> _blocks(Object? content) {
  if (content is String)
    return [
      {'type': 'text', 'text': content},
    ];
  if (content is! List) throw const ModelServiceFailure('invalid_request');
  return [
    for (final part in content)
      if (part is Map<String, dynamic>) part,
  ];
}

Map<String, dynamic> qoderRequest(
  Map<String, dynamic> chat,
  Map<String, dynamic> model,
) {
  final input = (chat['messages'] as List)
      .whereType<Map<String, dynamic>>()
      .toList();
  final system = input
      .where((m) => {'system', 'developer'}.contains(m['role']))
      .map((m) => _text(m['content']))
      .join('\n\n');
  final seed = jsonEncode([
    system,
    input.where((m) => m['role'] == 'user').firstOrNull?['content'] ?? '',
  ]);
  final hash = sha256.convert(utf8.encode(seed)).toString();
  final session =
      '${hash.substring(0, 8)}-${hash.substring(8, 12)}-${hash.substring(12, 16)}-${hash.substring(16, 20)}-${hash.substring(20, 32)}';
  final messages = <Map<String, dynamic>>[];
  var open = <String>{};
  for (final message in input) {
    final role = message['role'];
    if (role == 'system' || role == 'developer') continue;
    if (role == 'tool') {
      final call = message['tool_call_id'];
      if (call is! String || !open.remove(call))
        throw const ModelServiceFailure('invalid_tool_result');
      messages.add({
        'role': 'tool',
        'tool_call_id': call,
        'content': _text(message['content']),
      });
      continue;
    }
    if (role != 'user' && role != 'assistant')
      throw const ModelServiceFailure('invalid_request');
    open = {};
    final calls = message['tool_calls'];
    if (calls is List && calls.isNotEmpty) {
      for (final call in calls) {
        if (call is! Map ||
            call['id'] is! String ||
            call['function'] is! Map ||
            !open.add(call['id']))
          throw const ModelServiceFailure('invalid_tool_call');
      }
      messages.add({
        'role': role,
        'content': _text(message['content']),
        'tool_calls': calls,
        if (message['reasoning_content'] is String)
          'reasoning_content': message['reasoning_content'],
      });
    } else {
      messages.add({
        'role': role,
        'content': _blocks(message['content'] ?? ''),
        if (message['reasoning_content'] is String)
          'reasoning_content': message['reasoning_content'],
      });
    }
  }
  final key = model['key'];
  final request = qoderUuid();
  final thinking =
      model['is_reasoning'] == true && chat['reasoning_effort'] != 'none';
  final sys = [
    if (system.isNotEmpty) {'type': 'text', 'text': system},
  ];
  final config = {
    'key': key,
    'display_name': model['display_name'] ?? key,
    if (model['outer_provider'] != null)
      'outer_provider': model['outer_provider']
    else
      'model': '',
    'format': model['format'] ?? 'openai',
    'is_vl': model['is_vl'] == true,
    'is_reasoning': thinking,
    'api_key': '',
    'url': '',
    'source': model['source'] ?? 'system',
    if (model['max_input_tokens'] is int)
      'max_input_tokens': model['max_input_tokens'],
  };
  return {
    'request_id': request,
    'request_set_id': session,
    'chat_record_id': request,
    'session_id': session,
    'parameters': {
      'enable_thinking': thinking,
      'max_tokens': chat['max_completion_tokens'] ?? chat['max_tokens'] ?? 4096,
      if (chat['reasoning_effort'] is String && thinking)
        'reasoning_effort': chat['reasoning_effort'],
    },
    'business': {
      'product': 'app',
      'version': qoderCosyVersion,
      'type': 'agent',
      'id': session,
      'name': '',
      'begin_at': DateTime.now().millisecondsSinceEpoch,
      'stage': 'start',
      'model_key': key,
    },
    'agent_id': 'agent_common',
    'task_id': 'common',
    'session_type': 'app',
    'model_config': config,
    'system': sys,
    'messages': [
      if (sys.isNotEmpty) {'role': 'system', 'content': sys},
      ...messages,
    ],
    if (chat['tool_choice'] != 'none' && chat['tools'] is List)
      'tools': chat['tools'],
  };
}
