// Qoder's SSE envelope and declared-tool text forms, adapted from the MIT
// magpie-community Qoder adapter. No recovery loop or request resend.
import 'dart:async';
import 'dart:convert';
import 'model_provider.dart';
import 'qoder_protocol.dart';

/// Incremental Markdown delimiters for text tool extraction. A delimiter run
/// can cross content chunks; fences close only on their own line, and inline
/// code closes only with the same number of backticks that opened it. Four
/// columns of leading whitespace keep an indented code line entirely literal.
class _MarkdownCode {
  int _fence = 0, _fenceLength = 0, _inlineTicks = 0;
  int _run = 0, _runLength = 0, _indent = 0;
  bool _runAtStart = false,
      _lineStart = true,
      _closing = false,
      _escaped = false,
      _openingLine = false,
      _indented = false;

  bool get beforeTag {
    _finishRun();
    return _fence != 0 || _inlineTicks > 0 || _indented;
  }

  void _finishRun() {
    if (_runLength == 0) return;
    if (_fence != 0) {
      if (_openingLine && _fence == 96 && _run == 96) {
        // A backtick fence's info string cannot contain backticks. This is
        // instead an inline span, possibly already closed by this exact run.
        _inlineTicks = _runLength == _fenceLength ? 0 : _fenceLength;
        _fence = 0;
        _openingLine = false;
      } else {
        _closing = _run == _fence && _runAtStart && _runLength >= _fenceLength;
      }
    } else if (_inlineTicks > 0) {
      if (_run == 96 && _runLength == _inlineTicks) _inlineTicks = 0;
    } else if (_runAtStart && _runLength >= 3) {
      _fence = _run;
      _fenceLength = _runLength;
      _openingLine = _run == 96;
    } else if (_run == 96) {
      _inlineTicks = _runLength;
    }
    _lineStart = false;
    _runLength = 0;
  }

  void add(String text) {
    for (final char in text.codeUnits) {
      if (_indented && char != 10) continue;
      if (_runLength > 0 && char == _run) {
        _runLength++;
        continue;
      }
      _finishRun();
      if ((char == 96 || char == 126) && !_escaped) {
        _closing = false;
        _run = char;
        _runLength = 1;
        _runAtStart = _lineStart;
        continue;
      }
      if (char == 10) {
        _openingLine = false;
        if (_closing) {
          _fence = 0;
          _fenceLength = 0;
        }
        _closing = false;
        _lineStart = true;
        _indent = 0;
        _escaped = false;
        _indented = false;
        continue;
      }
      if (char != 32 && char != 9 && char != 13) _closing = false;
      if (_lineStart && (char == 32 || char == 9)) {
        _indent += char == 9 ? 4 - _indent % 4 : 1;
        if (_indent >= 4) {
          _lineStart = false;
          _indented = _fence == 0 && _inlineTicks == 0;
        }
      } else if (char != 13) {
        _lineStart = false;
      }
      _escaped = _fence == 0 && _inlineTicks == 0 && char == 92
          ? !_escaped
          : false;
    }
  }
}

class _ToolText {
  _ToolText(List tools)
    : tools = {
        for (final t in tools)
          if (t is Map && t['function'] is Map)
            t['function']['name']: t['function'],
      };
  final Map<dynamic, dynamic> tools;
  final _markdown = _MarkdownCode();
  String buffer = '';
  int index = 0;
  bool sawTool = false;
  Map<String, dynamic> _text(String text) {
    _markdown.add(text);
    return {'content': text};
  }

  String _unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
  Map<String, dynamic> _arguments(String name, String content) {
    final args = <String, dynamic>{};
    final parameters = RegExp(
      r'<(?:antml:)?parameter(?:\s+name\s*=\s*"([^"<>]+)"|=([^\s<>]+))\s*>([\s\S]*?)</(?:antml:)?parameter\s*>',
    );
    final schema = tools[name]?['parameters'];
    final properties = schema is Map ? schema['properties'] : null;
    var consumed = 0;
    for (final p in parameters.allMatches(content)) {
      if (content.substring(consumed, p.start).trim().isNotEmpty)
        throw const ModelServiceFailure('invalid_tool_response');
      final key = p.group(1) ?? p.group(2)!;
      final value = _unescape(p.group(3)!);
      final property = properties is Map ? properties[key] : null;
      if (property is Map && property['type'] == 'string') {
        args[key] = value;
      } else {
        try {
          args[key] = jsonDecode(value);
        } catch (_) {
          args[key] = value;
        }
      }
      consumed = p.end;
    }
    if (content.substring(consumed).trim().isNotEmpty)
      throw const ModelServiceFailure('invalid_tool_response');
    return args;
  }

  List<Map<String, dynamic>> feed(String text, {bool end = false}) {
    if (tools.isEmpty) return text.isEmpty ? [] : [_text(text)];
    buffer += text;
    if (buffer.length > 1024 * 1024)
      throw const ModelServiceFailure('invalid_tool_response');
    final out = <Map<String, dynamic>>[];
    while (buffer.isNotEmpty) {
      final at = buffer.indexOf('<');
      if (at < 0) {
        out.add(_text(buffer));
        buffer = '';
        break;
      }
      if (at > 0) {
        out.add(_text(buffer.substring(0, at)));
        buffer = buffer.substring(at);
      }
      if (_markdown.beforeTag) {
        out.add(_text(buffer[0]));
        buffer = buffer.substring(1);
        continue;
      }
      final wrapper = RegExp(
        r'^<(?:antml:)?function_calls>\s*',
      ).firstMatch(buffer);
      final offset = wrapper?.end ?? 0;
      final raw = buffer.substring(offset);
      final call = RegExp(
        r'^<(?:antml:)?invoke\s+name\s*=\s*"([^"<>]+)"\s*>|^<function=([^\s<>]+)\s*>',
      ).firstMatch(raw);
      final jsonCall = raw.startsWith('<tool_call>');
      if (call == null && !jsonCall) {
        final tail = RegExp(
          r'^\s*</(?:antml:)?function_calls>\s*',
        ).firstMatch(buffer);
        if (sawTool && tail != null) {
          buffer = buffer.substring(tail.end);
          continue;
        }
        final prefixes = [
          '<function_calls>',
          '<antml:function_calls>',
          '<invoke',
          '<antml:invoke',
          '<function=',
          '<tool_call>',
        ];
        final possible =
            prefixes.any((p) => p.startsWith(raw) || raw.startsWith(p)) ||
            wrapper != null && raw.isEmpty;
        if (possible && !end) break;
        if (possible && end && raw.contains('<parameter'))
          throw const ModelServiceFailure('invalid_tool_response');
        out.add(_text(buffer[0]));
        buffer = buffer.substring(1);
        continue;
      }
      String name;
      Map<String, dynamic> args;
      int consumed;
      if (jsonCall) {
        final close = raw.indexOf('</tool_call>');
        if (close < 0) {
          if (!end) break;
          throw const ModelServiceFailure('invalid_tool_response');
        }
        final inside = raw.substring(11, close).trim();
        final xml = RegExp(
          r'^<function=([^\s<>]+)\s*>([\s\S]*)</function\s*>$',
        ).firstMatch(inside);
        if (xml != null) {
          name = xml.group(1)!;
          args = _arguments(name, xml.group(2)!);
        } else {
          dynamic obj;
          try {
            obj = jsonDecode(inside);
          } catch (_) {
            throw const ModelServiceFailure('invalid_tool_response');
          }
          if (obj is! Map || obj['name'] is! String)
            throw const ModelServiceFailure('invalid_tool_response');
          name = obj['name'];
          final value = obj['arguments'] ?? obj['parameters'] ?? {};
          if (value is! Map<String, dynamic>)
            throw const ModelServiceFailure('invalid_tool_response');
          args = value;
        }
        consumed = close + 12;
      } else {
        name = (call!.group(1) ?? call.group(2)!).trim();
        if (!tools.containsKey(name)) {
          out.add(_text(buffer[0]));
          buffer = buffer.substring(1);
          continue;
        }
        final close = RegExp(
          call.group(2) != null
              ? r'</function\s*>'
              : r'</(?:antml:)?invoke\s*>',
        ).firstMatch(raw);
        if (close == null) {
          if (!end) break;
          throw const ModelServiceFailure('invalid_tool_response');
        }
        final content = raw.substring(call.end, close.start);
        args = _arguments(name, content);
        consumed = close.end;
      }
      if (!tools.containsKey(name)) {
        out.add(_text(buffer[0]));
        buffer = buffer.substring(1);
        continue;
      }
      sawTool = true;
      out.add({
        'tool_calls': [
          {
            'index': index++,
            'id': 'call_${qoderUuid()}',
            'type': 'function',
            'function': {'name': name, 'arguments': jsonEncode(args)},
          },
        ],
      });
      buffer = raw.substring(consumed);
    }
    return out;
  }
}

Map<String, dynamic> _failure(Object? value, int status) {
  Object? decoded = value;
  if (decoded is String) {
    try {
      decoded = jsonDecode(decoded.trim().replaceFirst(RegExp('^\uFEFF'), ''));
    } catch (_) {
      decoded = {'message': decoded};
    }
  }
  var body = decoded is Map ? decoded : const {};
  var code = '${body['code'] ?? ''}';
  if ({'', '401', '403'}.contains(code) && body['message'] is String) {
    try {
      final inner = jsonDecode((body['message'] as String).trim());
      if (inner is Map && '${inner['code']}' == '10605') {
        body = inner;
        code = '10605';
      }
    } catch (_) {}
  }
  Object? queue = body['queue'];
  if (queue is! Map && body['message'] is String) {
    try {
      queue = jsonDecode((body['message'] as String).trim());
    } catch (_) {}
  }
  final q = queue is Map ? queue : const {};
  Map<String, dynamic> result(int status, String code, [int? delay]) => {
    'failure': status,
    'errorCode': code,
    if (delay != null) 'retryAfterSeconds': delay,
  };
  if (code == '10605' ||
      q['isQueued'] == true ||
      q['serviceAvailable'] == false) {
    final delay = q['retryAfterSeconds'];
    return result(
      503,
      'upstream_queue',
      delay is num && delay.isFinite && delay > 0 ? delay.ceil() : 30,
    );
  }
  if ({
    '110',
    '112',
    '113',
    '114',
    '115',
    '116',
    '117',
    '118',
    '119',
    '122',
  }.contains(code))
    return result(429, 'quota_exhausted');
  if ({
    '406',
    '416',
    '430',
    '80411',
    '80412',
    '100400',
    '100401',
    '100403',
  }.contains(code))
    return result(400, 'request_rejected');
  final message = '${body['message'] ?? body['error'] ?? ''}';
  if (RegExp(
    r'range of max_tokens should be',
    caseSensitive: false,
  ).hasMatch(message))
    return result(400, 'invalid_request_parameter');
  if (RegExp(
    r'error in upstream response',
    caseSensitive: false,
  ).hasMatch(message))
    return result(502, 'upstream_unavailable');
  if (code == '105')
    return {
      ...result(401, 'authentication_required'),
      'credentialRejected': true,
    };
  if (status == 401 || status == 403)
    return result(401, 'authentication_required');
  return result(
    status >= 400 && status <= 599 ? status : 502,
    status == 429 ? 'upstream_rate_limited' : 'upstream_rejected',
  );
}

ModelReply _failureReply(Map<String, dynamic> failure, {ModelReply? upstream}) {
  final code = failure['errorCode'] as String;
  return ModelReply(
    failure['failure'],
    'application/json',
    Stream.value(
      utf8.encode(
        jsonEncode({
          'error': {'type': code, 'message': code},
        }),
      ),
    ),
    cancel: upstream?.cancel,
    errorCode: code,
    retryAfterSeconds:
        failure['retryAfterSeconds'] ?? upstream?.retryAfterSeconds,
    credentialRejected:
        failure['credentialRejected'] == true ||
        upstream?.credentialRejected == true,
  );
}

Stream<Map<String, dynamic>> _events(
  Stream<List<int>> body,
  List tools, {
  Future<void> Function()? onCredentialRejected,
}) async* {
  final text = _ToolText(tools);
  bool ended = false;
  String finish = '';
  Map<String, dynamic>? usage;
  final native = <int, Map<String, dynamic>>{};
  await for (final line
      in utf8.decoder.bind(body).transform(const LineSplitter())) {
    if (!line.startsWith('data:')) continue;
    if (line.length > 2 * 1024 * 1024)
      throw const ModelServiceFailure('response_too_large');
    final payload = line.substring(5).trim();
    if (payload.isEmpty) continue;
    dynamic envelope;
    try {
      envelope = jsonDecode(payload);
    } catch (_) {
      throw const ModelServiceFailure('invalid_upstream_stream');
    }
    if (envelope is! Map)
      throw const ModelServiceFailure('invalid_upstream_stream');
    dynamic inner = envelope['body'];
    if (inner is String) {
      inner = inner.trim().replaceFirst(RegExp('^\uFEFF'), '');
      if (inner == '[DONE]') {
        ended = true;
        break;
      }
      try {
        inner = jsonDecode(inner);
      } catch (_) {
        if (envelope['statusCodeValue'] == null ||
            envelope['statusCodeValue'] == 200)
          throw const ModelServiceFailure('invalid_upstream_stream');
      }
    }
    if (envelope['statusCodeValue'] != null &&
        envelope['statusCodeValue'] != 200) {
      final failure = _failure(
        inner,
        int.tryParse('${envelope['statusCodeValue']}') ?? 502,
      );
      if (failure['credentialRejected'] == true)
        await onCredentialRejected?.call();
      yield failure;
      return;
    }
    if (inner == null) continue;
    if (inner is! Map)
      throw const ModelServiceFailure('invalid_upstream_stream');
    if (inner['error'] != null ||
        inner['code'] != null && inner['choices'] is! List) {
      final failure = _failure(inner, 502);
      if (failure['credentialRejected'] == true)
        await onCredentialRejected?.call();
      yield failure;
      return;
    }
    if (inner['usage'] is Map)
      usage = Map<String, dynamic>.from(inner['usage']);
    final choices = inner['choices'];
    if (choices is! List || choices.isEmpty) continue;
    final choice = choices.first;
    if (choice is! Map) continue;
    final delta = choice['delta'];
    if (delta is Map) {
      if (delta['reasoning_content'] is String)
        yield {
          'delta': {'reasoning_content': delta['reasoning_content']},
        };
      if (delta['content'] is String)
        for (final d in text.feed(delta['content'])) {
          yield {'delta': d};
        }
      final calls = delta['tool_calls'];
      if (calls is List)
        for (final tc in calls) {
          if (tc is! Map)
            throw const ModelServiceFailure('invalid_tool_response');
          final i = tc['index'] is int ? tc['index'] as int : 0;
          final saved = native.putIfAbsent(
            i,
            () => {'id': '', 'name': '', 'arguments': '', 'sent': false},
          );
          if (tc['id'] is String) saved['id'] = tc['id'];
          final fn = tc['function'];
          if (fn is Map) {
            if (fn['name'] is String) saved['name'] = fn['name'];
            if (fn['arguments'] is String)
              saved['arguments'] += fn['arguments'];
          }
          if (saved['name'] == '' || saved['sent'] == true) continue;
          // Native fragments are kept until the full call is read, so an unnamed
          // or cut-short call can never become a persisted client tool turn.
        }
    }
    if (choice['finish_reason'] is String && choice['finish_reason'] != '')
      finish = choice['finish_reason'];
  }
  if (!ended && finish.isEmpty)
    throw const ModelServiceFailure('upstream_stream_incomplete');
  for (final d in text.feed('', end: true)) {
    yield {'delta': d};
  }
  for (final entry in native.entries) {
    final call = entry.value;
    if (call['name'] == '' || !text.tools.containsKey(call['name']))
      throw const ModelServiceFailure('invalid_tool_response');
    try {
      jsonDecode(call['arguments']);
    } catch (_) {
      throw const ModelServiceFailure('invalid_tool_response');
    }
    yield {
      'delta': {
        'tool_calls': [
          {
            'index': text.index++,
            'id': call['id'] == '' ? 'call_${qoderUuid()}' : call['id'],
            'type': 'function',
            'function': {'name': call['name'], 'arguments': call['arguments']},
          },
        ],
      },
    };
  }
  yield {
    'finish': text.sawTool || native.isNotEmpty
        ? 'tool_calls'
        : finish == 'length'
        ? 'length'
        : 'stop',
    if (usage != null) 'usage': usage,
  };
}

Future<void> consumeQoderReply(
  ModelReply upstream,
  Map<String, dynamic> chat,
  Future<void> Function(ModelReply) consume, {
  Future<void> Function()? onCredentialRejected,
}) async {
  if (upstream.status != 200) {
    final bytes = <int>[];
    await for (final chunk in upstream.body) {
      if (bytes.length + chunk.length > 2 * 1024 * 1024)
        throw const ModelServiceFailure('response_too_large');
      bytes.addAll(chunk);
    }
    final failure = _failure(
      utf8.decode(bytes, allowMalformed: true),
      upstream.status,
    );
    if (failure['credentialRejected'] == true)
      await onCredentialRejected?.call();
    await consume(_failureReply(failure, upstream: upstream));
    return;
  }
  final tools = chat['tools'] is List ? chat['tools'] as List : const [];
  final events = StreamIterator(
    _events(upstream.body, tools, onCredentialRejected: onCredentialRejected),
  );
  final id = 'chatcmpl-${qoderUuid()}', model = chat['model'];
  final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final options = chat['stream_options'];
  final includeUsage = options is! Map || options['include_usage'] != false;
  Map<String, dynamic> chunk(Map delta, {String? finish, Map? usage}) => {
    'id': id,
    'object': 'chat.completion.chunk',
    'created': created,
    'model': model,
    'choices': [
      {'index': 0, 'delta': delta, 'finish_reason': finish},
    ],
    if (usage != null) 'usage': usage,
  };
  try {
    if (!await events.moveNext())
      throw const ModelServiceFailure('upstream_stream_incomplete');
    if (events.current['failure'] is int) {
      await consume(_failureReply(events.current, upstream: upstream));
      return;
    }
    if (chat['stream'] == true) {
      Stream<List<int>> converted() async* {
        yield utf8.encode(
          'data: ${jsonEncode(chunk({'role': 'assistant', 'content': ''}))}\n\n',
        );
        do {
          final e = events.current;
          if (e['failure'] != null) {
            final code = e['errorCode'];
            yield utf8.encode(
              'data: ${jsonEncode({
                'error': {'type': code, 'message': code},
              })}\n\n',
            );
            return;
          }
          yield utf8.encode(
            'data: ${jsonEncode(chunk(e['delta'] ?? {}, finish: e['finish'], usage: includeUsage ? e['usage'] : null))}\n\n',
          );
        } while (await events.moveNext());
        yield utf8.encode('data: [DONE]\n\n');
      }

      await consume(
        ModelReply(
          200,
          'text/event-stream',
          converted(),
          cancel: upstream.cancel,
          errorCode: upstream.errorCode,
          retryAfterSeconds: upstream.retryAfterSeconds,
          credentialRejected: upstream.credentialRejected,
        ),
      );
    } else {
      var content = '', reasoning = '', finish = 'stop';
      Map? usage;
      final calls = <Map>[];
      do {
        final e = events.current;
        if (e['failure'] != null) {
          await consume(_failureReply(e, upstream: upstream));
          return;
        }
        final d = e['delta'];
        if (d is Map) {
          content += '${d['content'] ?? ''}';
          reasoning += '${d['reasoning_content'] ?? ''}';
          if (d['tool_calls'] is List)
            calls.addAll((d['tool_calls'] as List).cast<Map>());
        }
        if (e['finish'] is String) finish = e['finish'];
        if (e['usage'] is Map) usage = e['usage'];
      } while (await events.moveNext());
      final value = {
        'id': id,
        'object': 'chat.completion',
        'created': created,
        'model': model,
        'choices': [
          {
            'index': 0,
            'message': {
              'role': 'assistant',
              'content': content,
              if (reasoning.isNotEmpty) 'reasoning_content': reasoning,
              if (calls.isNotEmpty) 'tool_calls': calls,
            },
            'finish_reason': finish,
          },
        ],
        if (usage != null) 'usage': usage,
      };
      await consume(
        ModelReply(
          200,
          'application/json',
          Stream.value(utf8.encode(jsonEncode(value))),
          cancel: upstream.cancel,
          errorCode: upstream.errorCode,
          retryAfterSeconds: upstream.retryAfterSeconds,
          credentialRejected: upstream.credentialRejected,
        ),
      );
    }
  } finally {
    await events.cancel();
  }
}
