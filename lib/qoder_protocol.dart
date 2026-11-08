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

/// Catalog facts and request limits have one owner: the selected listing row.
class QoderModelSpec {
  QoderModelSpec(this.raw) {
    reasoning = raw['is_reasoning'] is bool ? raw['is_reasoning'] : null;
    efforts = _strings(raw['reasoning_efforts']);
    if (reasoning == null && efforts.isNotEmpty) reasoning = true;
    final tc = raw['thinking_config'];
    if (tc is Map) {
      final enabled = tc['enabled'];
      if (enabled is Map || tc.containsKey('enabled') || tc['disabled'] is Map)
        reasoning = enabled is Map;
      alwaysThinks = enabled is Map && tc['disabled'] == null;
      efforts = [];
      if (enabled is Map && enabled['efforts'] is Map) {
        for (final entry in (enabled['efforts'] as Map).entries) {
          if (entry.key is! String) continue;
          efforts.add(entry.key);
          if (entry.value is Map && entry.value['is_default'] == true)
            defaultEffort = entry.key;
        }
      }
    }
    thinks = reasoning == true;
    efforts.sort((a, b) => _rank(a).compareTo(_rank(b)));
    final context = raw['context_config'] ?? raw['contextConfig'];
    if (context is Map) {
      for (final entry in context.values) {
        if (entry is! Map) continue;
        final count = _positive(entry['token_count']);
        if (count == null) continue;
        windows.add(count);
        if ({true, 1, '1'}.contains(entry['is_default'])) defaultWindow = count;
      }
    }
    if (windows.isEmpty) {
      final available =
          raw['available_context_windows'] ?? raw['availableContextWindows'];
      if (available is List)
        for (final n in available) {
          if (_positive(n) case final count?) windows.add(count);
        }
      defaultWindow = _positive(
        raw['default_context_window'] ?? raw['defaultContextWindow'],
      );
      if (!windows.contains(defaultWindow)) defaultWindow = null;
    }
    windows = windows.toSet().toList()..sort();
  }
  final Map<String, dynamic> raw;
  bool thinks = false, alwaysThinks = false;
  bool? reasoning;
  List<String> efforts = [];
  String? defaultEffort;
  List<int> windows = [];
  int? defaultWindow;
  int? get contextWindow =>
      windows.isNotEmpty ? windows.last : _positive(raw['max_input_tokens']);
  int? get outputLimit =>
      _positive(raw['max_output_tokens'] ?? raw['maxOutputTokens']);
  List<String> get supportedEfforts => [
    if (thinks && !alwaysThinks) 'none',
    ...efforts,
  ];
  static const _order = [
    'none',
    'minimal',
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
    'ultra',
  ];
  static int _rank(String effort) =>
      _order.indexOf(effort) < 0 ? _order.length : _order.indexOf(effort);
  static int? _positive(Object? n) => n is int && n > 0 ? n : null;
  static List<String> _strings(Object? v) =>
      v is List ? v.whereType<String>().toSet().toList() : [];

  (bool, String?) thinking(Object? asked, int budget) {
    ModelDefinition(
      raw['key'] as String? ?? '',
      protocol: ModelProtocol.chat,
      reasoning: reasoning,
      alwaysThinks: alwaysThinks,
    ).validateInput({'reasoning_effort': asked});
    var want = asked is String ? asked.toLowerCase() : '';
    if (want == 'off') want = 'none';
    if (reasoning == null && want.isNotEmpty && want != 'none') {
      if (!_order.contains(want))
        throw const ModelServiceFailure('unsupported_reasoning_effort');
      return (true, want);
    }
    if (!_order.contains(want)) want = '';
    if (want == '' && budget > 0 && budget <= 1024) want = 'none';
    if (!thinks || want == 'none' && !alwaysThinks) return (false, null);
    if (efforts.isEmpty) return (true, null);
    if (want.isEmpty) return (true, defaultEffort);
    if (want == 'none') return (true, efforts.first);
    if (want == 'ultra' && !efforts.contains(want)) want = 'max';
    if (efforts.contains(want)) return (true, want);
    final at = _rank(want);
    final ranked = efforts.where((e) => e != 'none').toList()
      ..sort((a, b) {
        final distance = (_rank(a) - at).abs().compareTo((_rank(b) - at).abs());
        return distance == 0 ? _rank(b).compareTo(_rank(a)) : distance;
      });
    return (true, ranked.isEmpty ? null : ranked.first);
  }

  int? windowFor(Map<String, dynamic> chat, int output) {
    if (windows.isEmpty) return contextWindow;
    final base =
        defaultWindow ?? _positive(raw['max_input_tokens']) ?? contextWindow!;
    final need =
        (utf8
                    .encode(
                      jsonEncode({
                        'm': chat['messages'] ?? [],
                        't': chat['tools'] ?? [],
                      }),
                    )
                    .length /
                3)
            .ceil() +
        output;
    if (need <= base) return base;
    return windows.where((w) => w >= need).firstOrNull ?? windows.last;
  }
}

Object? _typedUnions(Object? schema) {
  if (schema is! Map) return schema;
  final root = jsonDecode(jsonEncode(schema)) as Map<String, dynamic>;
  bool object(Object? value, [Set<String> seen = const {}]) {
    if (value is! Map) return false;
    if (value.containsKey('type')) return value['type'] == 'object';
    final ref = value[r'$ref'];
    if (ref is! String ||
        !ref.startsWith('#/') ||
        seen.contains(ref) ||
        seen.length > 16)
      return false;
    Object? target = root;
    for (final key in ref.substring(2).split('/')) {
      target = target is Map
          ? target[key.replaceAll('~1', '/').replaceAll('~0', '~')]
          : null;
    }
    return object(target, {...seen, ref});
  }

  void walk(Object? value, int depth) {
    if (value is! Map || depth > 64) return;
    final union = value['oneOf'];
    if (!value.containsKey('type') &&
        union is List &&
        union.isNotEmpty &&
        union.every(object))
      value['type'] = 'object';
    for (final key in [
      'items',
      'additionalItems',
      'contains',
      'not',
      'if',
      'then',
      'else',
      'propertyNames',
      'additionalProperties',
      'unevaluatedProperties',
      'unevaluatedItems',
    ])
      walk(value[key], depth + 1);
    for (final key in ['anyOf', 'oneOf', 'allOf', 'prefixItems']) {
      if (value[key] is List)
        for (final item in value[key]) {
          walk(item, depth + 1);
        }
    }
    for (final key in [
      'properties',
      'patternProperties',
      r'$defs',
      'definitions',
      'dependentSchemas',
    ]) {
      if (value[key] is Map)
        for (final item in (value[key] as Map).values) {
          walk(item, depth + 1);
        }
    }
  }

  walk(root, 0);
  return root;
}

String _text(Object? content) {
  if (content == null) return '';
  if (content is String) return content;
  if (content is! List ||
      content.any(
        (b) => b is! Map || b['type'] != 'text' || b['text'] is! String,
      )) {
    throw const ModelServiceFailure('unsupported_content');
  }
  return content.map((b) => b['text']).join();
}

/// Refuse semantics the pinned COSY agent contract cannot represent before
/// route selection. Its generation parameters contain only thinking, output
/// budget and context length; ordinary Chat sampling/output fields are absent.
void validateQoderRequest(Map<String, dynamic> body) {
  const supported = {
    'model', 'messages', 'max_tokens', 'max_completion_tokens',
    'reasoning_effort', 'tools', 'tool_choice', 'stream',
    // Local request context and attribution, never invented COSY parameters.
    'metadata', 'user', 'prompt_cache_key', 'stream_options',
  };
  if (body.keys.any((key) => !supported.contains(key)))
    throw const ModelServiceFailure('unsupported_parameter');
  final options = body['stream_options'];
  if (options != null &&
      (options is! Map ||
          options.keys.any((key) => key != 'include_usage') ||
          options['include_usage'] != null &&
              options['include_usage'] is! bool))
    throw const ModelServiceFailure('unsupported_parameter');
  final choice = body['tool_choice'];
  if (choice != null && !{'auto', 'none', 'required'}.contains(choice))
    throw const ModelServiceFailure('unsupported_tool_choice');
  // These native message locations are strings, while user/assistant content
  // without tool calls can retain the vendor's multimodal block form.
  final messages = body['messages'];
  if (messages is! List) throw const ModelServiceFailure('invalid_request');
  for (final message in messages) {
    if (message is! Map) throw const ModelServiceFailure('invalid_request');
    if ({'system', 'developer', 'tool'}.contains(message['role']) ||
        message['role'] == 'assistant' &&
            message['tool_calls'] is List &&
            (message['tool_calls'] as List).isNotEmpty)
      _text(message['content']);
  }
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
  Map<String, dynamic> model, {
  ModelRequestContext? context,
  String? taskId,
  int? taskBeganAt,
  bool taskAnswered = false,
}) {
  validateQoderRequest(chat);
  final input = (chat['messages'] as List)
      .whereType<Map<String, dynamic>>()
      .toList();
  var system = input
      .where((m) => {'system', 'developer'}.contains(m['role']))
      .map((m) => _text(m['content']))
      .join('\n\n');
  final identity =
      context ?? ModelRequestContext.fromRequest(chat).forAccount('qoder');
  final session = identity.sessionId;
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
  final request = identity.requestId;
  final spec = QoderModelSpec(model);
  final budget = chat['max_completion_tokens'] ?? chat['max_tokens'];
  var output = budget is int && budget > 0 ? budget : 32000;
  final (thinking, effort) = spec.thinking(
    chat['reasoning_effort'],
    budget is int ? budget : 0,
  );
  if (spec.outputLimit case final limit?) {
    if (output > limit) output = limit;
  }
  final window = spec.windowFor(chat, output);
  if (chat['tool_choice'] == 'required' &&
      chat['tools'] is List &&
      (chat['tools'] as List).isNotEmpty)
    system += '\nYou must call an available function in this response.';
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
    'max_input_tokens':
        model['max_input_tokens'] is int && model['max_input_tokens'] > 0
        ? model['max_input_tokens']
        : 200000,
  };
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    if (message['role'] != 'user' || message['content'] is! List) continue;
    var blocks = List<Map<String, dynamic>>.from(message['content']);
    if (i == messages.length - 1 && blocks.isNotEmpty)
      blocks = [
        ...blocks.take(blocks.length - 1),
        {
          ...blocks.last,
          'cache_control': {'type': 'ephemeral'},
        },
      ];
    messages[i] = {...message, 'content': blocks, 'contents': blocks};
  }
  final task = taskId ?? identity.turnId;
  final prompt = input.where((m) => m['role'] == 'user').lastOrNull;
  final title = prompt == null
      ? ''
      : _text(
          prompt['content'] is String
              ? prompt['content']
              : (prompt['content'] as List? ?? [])
                    .where((p) => p is Map && p['type'] == 'text')
                    .toList(),
        );
  return {
    'request_id': request,
    'request_set_id': task,
    'chat_record_id': request,
    'session_id': session,
    'parameters': {
      'enable_thinking': thinking,
      'max_tokens': output,
      if (effort != null && effort.isNotEmpty) 'reasoning_effort': effort,
      if (window != null) 'context_length': window,
    },
    'business': {
      'product': 'app',
      'version': qoderCosyVersion,
      'type': 'agent',
      'id': task,
      'name': title.length > 10 ? title.substring(0, 10) : title,
      'begin_at': taskBeganAt ?? DateTime.now().millisecondsSinceEpoch,
      'stage': taskAnswered ? 'processing' : 'start',
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
      'tools': [
        for (final t in chat['tools'])
          if (t is Map &&
              t['type'] == 'function' &&
              t['function'] is Map &&
              t['function']['name'] is String)
            {
              'type': 'function',
              'function': {
                ...t['function'],
                'parameters':
                    _typedUnions(t['function']['parameters']) ??
                    {'type': 'object', 'properties': {}},
              },
            },
      ],
  };
}
