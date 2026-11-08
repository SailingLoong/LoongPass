import 'dart:convert';
import 'model_provider.dart';
import 'model_sse.dart';

Never _unsupported() => throw const ModelServiceFailure('unsupported_content');
Never _invalidReply() =>
    throw const ModelServiceFailure('invalid_upstream_response');

Object _chatContent(Object? value) {
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
              !{'adaptive', 'disabled'}.contains(thinking['type'])) ||
      output != null &&
          (output is! Map ||
              output.keys.any((k) => k != 'effort') ||
              !{
                'low',
                'medium',
                'high',
                'xhigh',
                'max',
              }.contains(output['effort']))) {
    throw const ModelServiceFailure('unsupported_request_parameter');
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
  final messages = <Map<String, dynamic>>[];
  if (body['system'] != null)
    messages.add({'role': 'system', 'content': _chatContent(body['system'])});
  if (body['messages'] is! List) _unsupported();
  for (final message in body['messages']) {
    if (message is! Map || !{'user', 'assistant'}.contains(message['role']))
      _unsupported();
    final content = message['content'];
    if (content is String) {
      messages.add({'role': message['role'], 'content': content});
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
              block['name'] is! String ||
              block['input'] is! Map)
            _unsupported();
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
      void flush() {
        if (parts.isNotEmpty) {
          messages.add({'role': 'user', 'content': _chatContent(parts)});
          parts.clear();
        }
      }

      for (final block in content) {
        if (block is! Map) _unsupported();
        if (block['type'] == 'tool_result') {
          flush();
          if (block['tool_use_id'] is! String) _unsupported();
          final result = _chatContent(block['content'] ?? '');
          messages.add({
            'role': 'tool',
            'tool_call_id': block['tool_use_id'],
            'content': block['is_error'] == true
                ? jsonEncode({'is_error': true, 'content': result})
                : result,
          });
        } else {
          parts.add(block);
        }
      }
      flush();
    }
  }
  final result = <String, dynamic>{
    'model': modelId,
    'messages': messages,
    if (body['max_tokens'] != null) 'max_tokens': body['max_tokens'],
    if (body['stream'] != null) 'stream': body['stream'],
    if (body['stream'] == true) 'stream_options': {'include_usage': true},
    for (final key in ['temperature', 'top_p'])
      if (body[key] != null) key: body[key],
    if (body['stop_sequences'] != null) 'stop': body['stop_sequences'],
    if (thinking is Map && thinking['type'] == 'disabled')
      'reasoning_effort': 'none'
    else if (output is Map)
      'reasoning_effort': output['effort']
    else if (thinking is Map && thinking['type'] == 'adaptive')
      'reasoning_effort': 'medium',
  };
  if (body['metadata'] case {'user_id': final String user})
    result['user'] = user;
  if (body['tools'] != null) {
    if (body['tools'] is! List) _unsupported();
    result['tools'] = [for (final tool in body['tools']) _chatTool(tool)];
  }
  final choice = body['tool_choice'];
  if (choice != null) {
    if (choice is! Map) _unsupported();
    result['tool_choice'] = switch (choice['type']) {
      'auto' => 'auto',
      'any' => 'required',
      'none' => 'none',
      'tool' when choice['name'] is String => {
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
  final cached = details is Map ? count(details['cached_tokens']) : 0;
  if (cached > total) _invalidReply();
  return {
    'input_tokens': total - cached,
    'output_tokens': count(raw['completion_tokens']),
    if (cached > 0) 'cache_read_input_tokens': cached,
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
