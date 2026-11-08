import 'dart:convert';

import 'model_provider.dart';
import 'model_sse.dart';

Never _unsupported() => throw const ModelServiceFailure('unsupported_content');
Never _invalidReply() =>
    throw const ModelServiceFailure('invalid_upstream_response');
String _toolLoadedText(String name) =>
    'Tool $name is loaded and can be called now.';

Object _chatContent(Object? value, {bool toolResult = false}) {
  if (value is String) return value;
  if (value is! List) _unsupported();
  final parts = <Map<String, dynamic>>[];
  for (final block in value) {
    if (block is! Map) _unsupported();
    switch (block['type']) {
      case 'text':
        if (block['text'] is! String) _unsupported();
        parts.add({
          'type': 'text',
          'text': block['text'],
          if (block['cache_control'] != null)
            'cache_control': block['cache_control'],
        });
      case 'image':
        final source = block['source'];
        if (source is! Map) _unsupported();
        final String url;
        if (source['type'] == 'base64' &&
            source['media_type'] is String &&
            source['data'] is String) {
          url = 'data:${source['media_type']};base64,${source['data']}';
        } else if (source['type'] == 'url' && source['url'] is String) {
          url = source['url'];
        } else {
          _unsupported();
        }
        parts.add({
          'type': 'image_url',
          'image_url': {'url': url},
        });
      case 'tool_reference' when toolResult:
        final name = block['tool_name'];
        if (name is! String || name.isEmpty) _unsupported();
        final previous = parts.isEmpty ? null : parts.last['text'];
        parts.add({
          'type': 'text',
          'text':
              '${previous is String && previous.isNotEmpty && !previous.endsWith('\n') ? '\n' : ''}${_toolLoadedText(name)}',
        });
      default:
        _unsupported();
    }
  }
  if (parts.every(
    (p) => p['type'] == 'text' && !p.containsKey('cache_control'),
  )) {
    return parts.map((p) => p['text']).join();
  }
  return parts;
}

/// Tool-loading metadata has one shared owner, before protocol conversion.
/// Current declarations win over historical definitions of the same name.
// Protocol reference: Magpie 8f6298f, anthropic_shapes.go (MIT). Unlike its
// metadata stripping, named removal here also retires inline-only definitions.
({List<Map<String, dynamic>> messages, List<Map<String, dynamic>> tools})
_chatToolLoading(Map<String, dynamic> body) {
  final current = <String>{};
  final known = <String, Map<String, dynamic>>{};
  final active = <String, Map<String, dynamic>>{};
  final references = <String>{};
  String nameOf(Object? value) {
    if (value is! String || value.isEmpty) _unsupported();
    return value;
  }

  ({String name, bool restored}) declare(
    Object? definition, {
    bool topLevel = false,
  }) {
    final wire = _chatTool(definition);
    final name = nameOf(wire['function']['name']);
    final restored = known.containsKey(name) && !active.containsKey(name);
    if (topLevel) current.add(name);
    if (topLevel || !current.contains(name)) {
      known[name] = wire;
      active[name] = wire;
    }
    return (name: name, restored: restored);
  }

  if (body['tools'] != null) {
    if (body['tools'] is! List) _unsupported();
    for (final tool in body['tools']) {
      if (tool is Map && tool['name'] == 'DeferredToolPlaceholder') continue;
      declare(tool, topLevel: true);
    }
  }

  List<Map<String, dynamic>> content(List blocks, {bool result = false}) {
    final out = <Map<String, dynamic>>[];
    for (final block in blocks) {
      if (block is! Map<String, dynamic>) _unsupported();
      switch (block['type']) {
        case 'tool_addition' when !result:
        case 'tool_removal' when !result:
          final tool = block['tool'];
          if (tool is! Map) _unsupported();
          if (block['type'] == 'tool_addition' &&
              tool['type'] == 'tool_definition') {
            final declaration = declare(tool['definition']);
            if (declaration.restored) {
              out.add({
                'type': 'text',
                'text': _toolLoadedText(declaration.name),
              });
            }
          } else if (tool['type'] == 'tool_reference') {
            if (tool.keys.any((key) => !{'type', 'name'}.contains(key)))
              _unsupported();
            final name = nameOf(tool['name']);
            if (block['type'] == 'tool_removal') {
              if (!known.containsKey(name)) _unsupported();
              if (!current.contains(name)) {
                active.remove(name);
                out.add({
                  'type': 'text',
                  'text': 'Tool $name is no longer available.',
                });
              }
            } else {
              references.add(name);
              if (!current.contains(name) && known.containsKey(name)) {
                if (!active.containsKey(name)) {
                  out.add({'type': 'text', 'text': _toolLoadedText(name)});
                }
                active[name] = known[name]!;
              }
            }
          } else {
            _unsupported();
          }
        case 'tool_definition':
          final declaration = declare(block['definition']);
          if (result) {
            out.add({'type': 'tool_reference', 'tool_name': declaration.name});
          } else if (declaration.restored) {
            out.add({
              'type': 'text',
              'text': _toolLoadedText(declaration.name),
            });
          }
        case 'tool_reference':
          final name = nameOf(block['tool_name']);
          references.add(name);
          out.add(
            result ? block : {'type': 'text', 'text': _toolLoadedText(name)},
          );
        case 'tool_result' when !result:
          final value = block['content'];
          out.add({
            ...block,
            if (value is List) 'content': content(value, result: true),
          });
        default:
          out.add(block);
      }
    }
    return out;
  }

  if (body['messages'] is! List) _unsupported();
  final messages = <Map<String, dynamic>>[];
  for (final message in body['messages']) {
    if (message is! Map<String, dynamic> ||
        !{'user', 'assistant', 'system'}.contains(message['role']))
      _unsupported();
    final value = message['content'];
    if (value is! List) {
      messages.add(message);
      continue;
    }
    final normalized = content(value);
    if (value.isNotEmpty && normalized.isEmpty) continue;
    messages.add({...message, 'content': normalized});
  }
  if (references.any((name) => !known.containsKey(name))) _unsupported();
  return (messages: messages, tools: active.values.toList());
}

({Object text, List<Map<String, dynamic>> images}) _chatToolOutput(
  Object? value,
) {
  if (value is String) return (text: value, images: []);
  if (value is! List) _unsupported();
  final text = <Map<String, dynamic>>[], images = <Map<String, dynamic>>[];
  for (final block in value) {
    if (block is! Map<String, dynamic>) _unsupported();
    (block['type'] == 'image' ? images : text).add(block);
  }
  var output = _chatContent(text, toolResult: true);
  if (images.isNotEmpty) {
    _chatContent(images); // Validate each image before constructing the wire.
    final note = images.length == 1
        ? '[The tool returned an image; it follows in the next message.]'
        : '[The tool returned ${images.length} images; they follow in the next message.]';
    output = output is String
        ? (output.isEmpty ? note : '$output\n\n$note')
        : [
            ...output as List,
            {'type': 'text', 'text': '\n\n$note'},
          ];
  }
  return (text: output, images: images);
}

/// One protocol boundary after routing. No prompts, model versions, tools or
/// history are guessed. Unsupported semantic fields fail before dispatch.
Map<String, dynamic> messagesToChat(Map<String, dynamic> body, String modelId) {
  const allowed = {
    'model',
    'messages',
    'max_tokens',
    'stream',
    'system',
    'temperature',
    'top_p',
    'stop_sequences',
    'tools',
    'tool_choice',
    'metadata',
    'thinking',
    'output_config',
    'context_management',
  };
  if (body.keys.any((k) => !allowed.contains(k))) {
    throw const ModelServiceFailure('unsupported_request_parameter');
  }
  final thinking = body['thinking'], output = body['output_config'];
  if (thinking != null &&
          (thinking is! Map ||
              !{
                'adaptive',
                'disabled',
                'enabled',
                'between_tools',
              }.contains(thinking['type']) ||
              thinking.keys.any(
                (k) => !{'type', 'display', 'budget_tokens'}.contains(k),
              ) ||
              thinking['type'] == 'enabled' &&
                  (thinking['budget_tokens'] is! int ||
                      thinking['budget_tokens'] <= 0)) ||
      output != null &&
          (output is! Map ||
              output.keys.any((k) => !{'effort', 'format'}.contains(k)) ||
              output.containsKey('effort') &&
                  !{
                    'low',
                    'medium',
                    'high',
                    'xhigh',
                    'max',
                  }.contains(output['effort']))) {
    throw const ModelServiceFailure('unsupported_request_parameter');
  }
  final format = output is Map ? output['format'] : null;
  if (format != null &&
      (format is! Map ||
          format['type'] != 'json_schema' ||
          format['schema'] is! Map ||
          format.keys.any((k) => !{'type', 'schema'}.contains(k)))) {
    throw const ModelServiceFailure('unsupported_request_parameter');
  }
  String? effort;
  if (thinking is Map) {
    if ({'disabled', 'between_tools'}.contains(thinking['type'])) {
      effort = 'none';
    } else if (output is Map && output['effort'] is String) {
      effort = output['effort'];
    } else if (thinking['type'] == 'enabled') {
      final budget = thinking['budget_tokens'] as int;
      effort = budget <= 4096
          ? 'low'
          : budget <= 12000
          ? 'medium'
          : budget <= 24000
          ? 'high'
          : 'xhigh';
    } else {
      effort = 'medium';
    }
  }
  // Claude Code asks to keep every thinking block. This context-edit policy is
  // a no-op on the full transcript we send. Actual destructive context edits
  // are refused rather than silently discarding history on another protocol.
  final context = body['context_management'];
  if (context != null &&
      (context is! Map ||
          context.keys.any((k) => k != 'edits') ||
          context['edits'] is! List ||
          (context['edits'] as List).any(
            (edit) =>
                edit is! Map ||
                edit['type'] != 'clear_thinking_20251015' ||
                edit['keep'] != 'all' ||
                edit.keys.any((k) => !{'type', 'keep'}.contains(k)),
          ))) {
    throw const ModelServiceFailure('unsupported_request_parameter');
  }
  final loading = _chatToolLoading(body);
  final messages = <Map<String, dynamic>>[];
  final images = <Map<String, dynamic>>[];
  final userParts = <Map>[];
  final awaitingResults = <String>{};
  final toolNames = <String, String>{};
  void userContent(List<Map> parts, {bool force = false}) {
    userParts.addAll(parts);
    if (!force && awaitingResults.isNotEmpty) return;
    if (userParts.isEmpty && images.isEmpty) return;
    messages.add({
      'role': 'user',
      'content': _chatContent([...images, ...userParts]),
    });
    images.clear();
    userParts.clear();
  }

  if (body['system'] != null)
    messages.add({'role': 'system', 'content': _chatContent(body['system'])});
  for (final message in loading.messages) {
    if (message['role'] != 'user' &&
        (images.isNotEmpty || userParts.isNotEmpty))
      userContent([], force: true);
    final content = message['content'];
    // Claude Code also sends per-turn environment updates inside messages.
    // Chat can represent them directly; keep their role and original position.
    if (content is String || message['role'] == 'system') {
      if (message['role'] == 'user' &&
          (images.isNotEmpty ||
              userParts.isNotEmpty ||
              awaitingResults.isNotEmpty)) {
        userContent([
          {'type': 'text', 'text': content},
        ]);
      } else {
        messages.add({
          'role': message['role'],
          'content': _chatContent(content),
        });
      }
      continue;
    }
    if (content is! List) _unsupported();
    if (message['role'] == 'assistant') {
      final text = <Map>[];
      final tools = <Map<String, dynamic>>[];
      final reasoning = StringBuffer();
      for (final block in content) {
        if (block is! Map) _unsupported();
        if (block['type'] == 'tool_use') {
          if (block['id'] is! String ||
              (block['id'] as String).isEmpty ||
              block['name'] is! String ||
              (block['name'] as String).isEmpty ||
              block['input'] is! Map)
            _unsupported();
          toolNames[block['id']] = block['name'];
          awaitingResults.add(block['id']);
          tools.add({
            'id': block['id'],
            'type': 'function',
            'function': {
              'name': block['name'],
              'arguments': jsonEncode(block['input']),
            },
          });
        } else if (block['type'] == 'thinking' &&
            block['thinking'] is String &&
            (block['signature'] == null || block['signature'] == '')) {
          reasoning.write(block['thinking']);
        } else if (block['type'] == 'text') {
          text.add(block);
        } else {
          _unsupported();
        }
      }
      messages.add({
        'role': 'assistant',
        'content': text.isEmpty ? null : _chatContent(text),
        if (tools.isNotEmpty) 'tool_calls': tools,
        if (reasoning.isNotEmpty) 'reasoning_content': reasoning.toString(),
      });
    } else {
      final parts = <Map>[];
      for (final block in content) {
        if (block is! Map) _unsupported();
        if (block['type'] == 'tool_result') {
          final id = block['tool_use_id'];
          if (id is! String || id.isEmpty) _unsupported();
          final result = _chatToolOutput(block['content'] ?? '');
          awaitingResults.remove(id);
          messages.add({
            'role': 'tool',
            'tool_call_id': id,
            'content': block['is_error'] == true
                ? jsonEncode({'is_error': true, 'content': result.text})
                : result.text,
          });
          if (result.images.isNotEmpty) {
            final name = toolNames[id];
            final attribution = name == null
                ? 'tool call $id'
                : '$name (tool call $id)';
            images.addAll([
              {'type': 'text', 'text': '[From the result of $attribution:]'},
              ...result.images,
            ]);
          }
        } else {
          parts.add(block);
        }
      }
      // Tool messages must stay together immediately after their tool calls.
      if (parts.isNotEmpty || userParts.isNotEmpty) userContent(parts);
    }
  }
  if (images.isNotEmpty || userParts.isNotEmpty) userContent([], force: true);
  final result = <String, dynamic>{
    'model': modelId,
    'messages': messages,
    if (body['max_tokens'] != null) 'max_tokens': body['max_tokens'],
    if (body['stream'] != null) 'stream': body['stream'],
    if (body['stream'] == true) 'stream_options': {'include_usage': true},
    for (final key in ['temperature', 'top_p'])
      if (body[key] != null) key: body[key],
    if (body['stop_sequences'] != null) 'stop': body['stop_sequences'],
    if (effort != null) 'reasoning_effort': effort,
    if (format is Map)
      'response_format': {
        'type': 'json_schema',
        'json_schema': {'name': 'response', 'schema': format['schema']},
      },
  };
  if (body['metadata'] case {'user_id': final String user})
    result['user'] = user;
  if (body['tools'] != null || loading.tools.isNotEmpty)
    result['tools'] = loading.tools;
  final choice = body['tool_choice'];
  if (choice != null) {
    if (choice is! Map) _unsupported();
    result['tool_choice'] = switch (choice['type']) {
      'auto' => 'auto',
      'any' => 'required',
      'none' => 'none',
      'tool'
          when choice['name'] is String &&
              loading.tools.any(
                (tool) => tool['function']['name'] == choice['name'],
              ) =>
        {
          'type': 'function',
          'function': {'name': choice['name']},
        },
      _ => _unsupported(),
    };
    if (choice['disable_parallel_tool_use'] is bool) {
      result['parallel_tool_calls'] =
          choice['disable_parallel_tool_use'] != true;
    }
  }
  return result;
}

Map<String, dynamic> _chatTool(Object? tool) {
  if (tool is! Map ||
      tool['name'] is! String ||
      tool['input_schema'] is! Map ||
      tool['description'] != null && tool['description'] is! String ||
      tool['defer_loading'] != null && tool['defer_loading'] is! bool ||
      tool['type'] != null && tool['type'] != 'custom')
    _unsupported();
  return {
    'type': 'function',
    'function': {
      'name': tool['name'],
      if (tool['description'] != null) 'description': tool['description'],
      'parameters': tool['input_schema'],
    },
    if (tool['cache_control'] != null) 'cache_control': tool['cache_control'],
  };
}

Map<String, dynamic> _usage(Object? value) {
  final raw = value is Map ? value : const {};
  int count(Object? n) => n is int && n >= 0 ? n : 0;
  final total = count(raw['prompt_tokens']);
  final details = raw['prompt_tokens_details'];
  var cached = details is Map ? count(details['cached_tokens']) : 0;
  var written = details is Map ? count(details['cache_write_tokens']) : 0;
  if (cached == 0) cached = count(raw['prompt_cache_hit_tokens']);
  if (cached == 0) cached = count(raw['cached_tokens']);
  var whole = true;
  if (cached == 0 && written == 0) {
    cached = count(raw['cache_read_input_tokens']);
    written = count(raw['cache_creation_input_tokens']);
    // Some Messages relays retain Anthropic's uncached prompt count.
    whole = total >= cached + written;
  } else if (cached + written > total) {
    _invalidReply();
  }
  return {
    'input_tokens': whole ? total - cached - written : total,
    'output_tokens': count(raw['completion_tokens']),
    if (cached > 0) 'cache_read_input_tokens': cached,
    if (written > 0) 'cache_creation_input_tokens': written,
  };
}

String _stop(Object? value) => switch (value) {
  'stop' => 'end_turn',
  'tool_calls' || 'function_call' => 'tool_use',
  'length' => 'max_tokens',
  _ => throw const ModelServiceFailure('upstream_response_incomplete'),
};

Map<String, dynamic> _toolBlock(Map raw) {
  final fn = raw['function'];
  if (raw['id'] is! String ||
      (raw['id'] as String).isEmpty ||
      fn is! Map ||
      fn['name'] is! String ||
      (fn['name'] as String).isEmpty ||
      fn['arguments'] is! String)
    _invalidReply();
  Object? input;
  try {
    input = jsonDecode(fn['arguments']);
  } catch (_) {
    _invalidReply();
  }
  if (input is! Map<String, dynamic>) _invalidReply();
  return {
    'type': 'tool_use',
    'id': raw['id'],
    'name': fn['name'],
    'input': input,
  };
}

Map<String, dynamic> messagesFromChat(
  Map<String, dynamic> raw,
  String modelId,
) {
  final choices = raw['choices'];
  if (choices is! List || choices.length != 1 || choices.single is! Map)
    _invalidReply();
  final choice = choices.single as Map, message = choice['message'];
  if (message is! Map) _invalidReply();
  final content = <Map<String, dynamic>>[];
  if (message['reasoning_content'] is String &&
      (message['reasoning_content'] as String).isNotEmpty) {
    content.add({'type': 'thinking', 'thinking': message['reasoning_content']});
  }
  if (message['content'] is String) {
    if ((message['content'] as String).isNotEmpty)
      content.add({'type': 'text', 'text': message['content']});
  } else if (message['content'] != null) {
    _invalidReply();
  }
  if (message['tool_calls'] != null) {
    if (message['tool_calls'] is! List) _invalidReply();
    for (final tool in message['tool_calls']) {
      if (tool is! Map) _invalidReply();
      content.add(_toolBlock(tool));
    }
  }
  return {
    'id': raw['id'] is String ? raw['id'] : 'msg_loongpass',
    'type': 'message',
    'role': 'assistant',
    'model': modelId,
    'content': content,
    'stop_reason': _stop(choice['finish_reason']),
    'stop_sequence': null,
    'usage': _usage(raw['usage']),
  };
}

Future<ModelReply> messagesChatReply(
  ModelReply reply, {
  required String modelId,
  required bool stream,
}) async {
  if (reply.status < 200 || reply.status >= 300) return reply;
  if (reply.contentType.toLowerCase().contains('text/event-stream')) {
    if (!stream) throw const ModelServiceFailure('unexpected_upstream_stream');
    return ModelReply(
      reply.status,
      'text/event-stream',
      _chatStream(reply.body, modelId),
      cancel: reply.cancel,
      errorCode: reply.errorCode,
      retryAfterSeconds: reply.retryAfterSeconds,
      credentialRejected: reply.credentialRejected,
    );
  }
  final bytes = <int>[];
  await for (final part in reply.body) {
    if (bytes.length + part.length > 4 * 1024 * 1024)
      throw const ModelServiceFailure('upstream_response_too_large');
    bytes.addAll(part);
  }
  final Object? raw;
  try {
    raw = jsonDecode(utf8.decode(bytes));
  } catch (_) {
    _invalidReply();
  }
  if (raw is! Map<String, dynamic>) _invalidReply();
  final message = messagesFromChat(raw, modelId);
  return ModelReply(
    reply.status,
    stream ? 'text/event-stream' : 'application/json',
    stream
        ? _wholeStream(message)
        : Stream.value(utf8.encode(jsonEncode(message))),
    cancel: reply.cancel,
    errorCode: reply.errorCode,
    retryAfterSeconds: reply.retryAfterSeconds,
    credentialRejected: reply.credentialRejected,
  );
}

Future<ModelReply> messagesNativeReply(
  ModelReply reply, {
  required String modelId,
  required bool stream,
}) async {
  if (reply.contentType.toLowerCase().contains('text/event-stream')) {
    if (!stream) throw const ModelServiceFailure('unexpected_upstream_stream');
    return ModelReply(
      reply.status,
      'text/event-stream',
      (() async* {
        var finished = false;
        await for (final event in modelSseEvents(reply.body)) {
          final Object? data;
          try {
            data = jsonDecode(event.data);
          } catch (_) {
            _invalidReply();
          }
          if (data is! Map<String, dynamic> || data['type'] == 'error')
            _invalidReply();
          if (data['type'] == 'message_start' && data['message'] is Map)
            data['message']['model'] = modelId;
          yield ModelSseEvent(event.event, jsonEncode(data)).encode();
          if (data['type'] == 'message_stop') {
            finished = true;
            break;
          }
        }
        if (!finished)
          throw const ModelServiceFailure('upstream_response_incomplete');
      })(),
      cancel: reply.cancel,
      errorCode: reply.errorCode,
      retryAfterSeconds: reply.retryAfterSeconds,
      credentialRejected: reply.credentialRejected,
    );
  }
  final bytes = <int>[];
  await for (final part in reply.body) {
    if (bytes.length + part.length > 4 * 1024 * 1024)
      throw const ModelServiceFailure('upstream_response_too_large');
    bytes.addAll(part);
  }
  final Object? message;
  try {
    message = jsonDecode(utf8.decode(bytes));
  } catch (_) {
    _invalidReply();
  }
  if (message is! Map<String, dynamic> ||
      message['type'] != 'message' ||
      message['content'] is! List ||
      message['stop_reason'] == null)
    _invalidReply();
  message['model'] = modelId;
  return ModelReply(
    reply.status,
    stream ? 'text/event-stream' : 'application/json',
    stream
        ? _wholeStream(message)
        : Stream.value(utf8.encode(jsonEncode(message))),
    cancel: reply.cancel,
    errorCode: reply.errorCode,
    retryAfterSeconds: reply.retryAfterSeconds,
    credentialRejected: reply.credentialRejected,
  );
}

List<int> _event(String type, Map<String, dynamic> data) =>
    ModelSseEvent(type, jsonEncode({'type': type, ...data})).encode();

Stream<List<int>> _wholeStream(Map<String, dynamic> message) async* {
  yield _event('message_start', {
    'message': {
      ...message,
      'content': [],
      'stop_reason': null,
      'usage': {...message['usage'], 'output_tokens': 0},
    },
  });
  var index = 0;
  for (final block in message['content']) {
    yield _event('content_block_start', {
      'index': index,
      'content_block': block,
    });
    yield _event('content_block_stop', {'index': index++});
  }
  yield _event('message_delta', {
    'delta': {'stop_reason': message['stop_reason'], 'stop_sequence': null},
    'usage': message['usage'],
  });
  yield _event('message_stop', {});
}

Stream<List<int>> _chatStream(Stream<List<int>> body, String modelId) async* {
  var started = false, done = false, index = 0, size = 0;
  String? reason;
  var usage = <String, dynamic>{'input_tokens': 0, 'output_tokens': 0};
  final open = <String, int>{}, tools = <int, Map<String, dynamic>>{};
  await for (final event in modelSseEvents(body)) {
    if (event.data == '[DONE]') {
      done = true;
      break;
    }
    final Object? raw;
    try {
      raw = jsonDecode(event.data);
    } catch (_) {
      _invalidReply();
    }
    if (raw is! Map || raw['error'] != null) _invalidReply();
    if (!started) {
      started = true;
      yield _event('message_start', {
        'message': {
          'id': raw['id'] is String ? raw['id'] : 'msg_loongpass',
          'type': 'message',
          'role': 'assistant',
          'model': modelId,
          'content': [],
          'stop_reason': null,
          'stop_sequence': null,
          'usage': usage,
        },
      });
    }
    if (raw['usage'] != null) usage = _usage(raw['usage']);
    final choices = raw['choices'];
    if (choices is! List || choices.length > 1) _invalidReply();
    if (choices.isEmpty) continue;
    final choice = choices.single;
    if (choice is! Map) _invalidReply();
    if (choice['finish_reason'] != null && choice['finish_reason'] != '')
      reason = _stop(choice['finish_reason']);
    final delta = choice['delta'];
    if (delta is! Map) _invalidReply();
    for (final entry in [
      ('reasoning_content', 'thinking', 'thinking_delta', 'thinking'),
      ('content', 'text', 'text_delta', 'text'),
    ]) {
      final value = delta[entry.$1];
      if (value == null || value == '') continue;
      if (value is! String) _invalidReply();
      if (!open.containsKey(entry.$1)) {
        open[entry.$1] = index++;
        yield _event('content_block_start', {
          'index': open[entry.$1],
          'content_block': {'type': entry.$2, entry.$4: ''},
        });
      }
      yield _event('content_block_delta', {
        'index': open[entry.$1],
        'delta': {'type': entry.$3, entry.$4: value},
      });
    }
    final calls = delta['tool_calls'];
    if (calls != null && calls is! List) _invalidReply();
    for (final call in calls ?? const []) {
      if (call is! Map ||
          call['index'] is! int ||
          call['index'] < 0 ||
          call['index'] > 255)
        _invalidReply();
      final tool = tools.putIfAbsent(
        call['index'],
        () => {
          'id': '',
          'function': {'name': '', 'arguments': ''},
        },
      );
      if (call['id'] is String) tool['id'] = '${tool['id']}${call['id']}';
      final fn = call['function'];
      if (fn != null && fn is! Map) _invalidReply();
      for (final field in ['name', 'arguments']) {
        if (fn?[field] == null) continue;
        if (fn[field] is! String) _invalidReply();
        size += (fn[field] as String).length;
        if (size > 2 * 1024 * 1024)
          throw const ModelServiceFailure('upstream_event_too_large');
        tool['function'][field] = '${tool['function'][field]}${fn[field]}';
      }
    }
  }
  if (!started || !done || reason == null)
    throw const ModelServiceFailure('upstream_response_incomplete');
  for (final blockIndex in open.values)
    yield _event('content_block_stop', {'index': blockIndex});
  for (final key in tools.keys.toList()..sort()) {
    final tool = _toolBlock(tools[key]!);
    yield _event('content_block_start', {
      'index': index,
      'content_block': {...tool, 'input': <String, dynamic>{}},
    });
    yield _event('content_block_delta', {
      'index': index,
      'delta': {
        'type': 'input_json_delta',
        'partial_json': jsonEncode(tool['input']),
      },
    });
    yield _event('content_block_stop', {'index': index++});
  }
  yield _event('message_delta', {
    'delta': {'stop_reason': reason, 'stop_sequence': null},
    'usage': usage,
  });
  yield _event('message_stop', {});
}
