// Qoder's SSE envelope and declared-tool text forms, adapted from the MIT
// magpie-community Qoder adapter. No recovery loop or request resend.
import 'dart:async';
import 'dart:convert';
import 'model_provider.dart';
import 'qoder_protocol.dart';

class _ToolText {
  _ToolText(List tools)
    : tools = {
        for (final t in tools)
          if (t is Map && t['function'] is Map)
            t['function']['name']: t['function'],
      };
  final Map<dynamic, dynamic> tools;
  String buffer = '', sent = '';
  int index = 0;
  bool sawTool = false;
  Map<String, dynamic> _text(String text) {
    sent += text;
    return {'content': text};
  }

  String _unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
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
      final codeFence = '```'.allMatches(sent).length.isOdd;
      if (codeFence) {
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
        dynamic obj;
        try {
          obj = jsonDecode(raw.substring(11, close));
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
        args = {};
        final parameters = RegExp(
          r'<(?:antml:)?parameter(?:\s+name\s*=\s*"([^"<>]+)"|=([^\s<>]+))\s*>([\s\S]*?)</(?:antml:)?parameter\s*>',
        );
        final schema = tools[name]?['parameters'];
        final properties = schema is Map ? schema['properties'] : null;
        var consumedParameter = 0;
        for (final p in parameters.allMatches(content)) {
          if (content.substring(consumedParameter, p.start).trim().isNotEmpty)
            throw const ModelServiceFailure('invalid_tool_response');
          final key = p.group(1) ?? p.group(2)!;
          final value = _unescape(p.group(3)!);
          final property = properties is Map ? properties[key] : null;
          if (property is Map &&
              property['type'] != null &&
              property['type'] != 'string') {
            try {
              args[key] = jsonDecode(value);
            } catch (_) {
              throw const ModelServiceFailure('invalid_tool_response');
            }
          } else {
            args[key] = value;
          }
          consumedParameter = p.end;
        }
        if (content.substring(consumedParameter).trim().isNotEmpty)
          throw const ModelServiceFailure('invalid_tool_response');
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

int _failureStatus(Map value, int status) {
  final code = '${value['code'] ?? ''}';
  if (code == '10605') return 503;
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
    return 429;
  if (code == '105') return 401;
  return status >= 400 && status <= 599 ? status : 502;
}

Stream<Map<String, dynamic>> _events(
  Stream<List<int>> body,
  List tools,
) async* {
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
        throw const ModelServiceFailure('invalid_upstream_stream');
      }
    }
    if (envelope['statusCodeValue'] != null &&
        envelope['statusCodeValue'] != 200) {
      yield {
        'failure': _failureStatus(
          inner is Map ? inner : {},
          int.tryParse('${envelope['statusCodeValue']}') ?? 502,
        ),
      };
      return;
    }
    if (inner == null) continue;
    if (inner is! Map)
      throw const ModelServiceFailure('invalid_upstream_stream');
    if (inner['error'] != null ||
        inner['code'] != null && inner['choices'] is! List) {
      yield {'failure': _failureStatus(inner, 502)};
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
  Future<void> Function(ModelReply) consume,
) async {
  if (upstream.status != 200) {
    await consume(upstream);
    return;
  }
  final tools = chat['tools'] is List ? chat['tools'] as List : const [];
  final events = StreamIterator(_events(upstream.body, tools));
  final id = 'chatcmpl-${qoderUuid()}', model = chat['model'];
  final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
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
      await consume(
        ModelReply(
          events.current['failure'],
          'application/json',
          const Stream.empty(),
          cancel: upstream.cancel,
        ),
      );
      return;
    }
    if (chat['stream'] == true) {
      Stream<List<int>> converted() async* {
        yield utf8.encode(
          'data: ${jsonEncode(chunk({'role': 'assistant', 'content': ''}))}\n\n',
        );
        do {
          final e = events.current;
          if (e['failure'] != null)
            throw const ModelServiceFailure('upstream_stream_incomplete');
          yield utf8.encode(
            'data: ${jsonEncode(chunk(e['delta'] ?? {}, finish: e['finish'], usage: e['usage']))}\n\n',
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
        ),
      );
    } else {
      var content = '', reasoning = '', finish = 'stop';
      Map? usage;
      final calls = <Map>[];
      do {
        final e = events.current;
        if (e['failure'] != null) {
          await consume(
            ModelReply(e['failure'], 'application/json', const Stream.empty()),
          );
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
        ),
      );
    }
  } finally {
    await events.cancel();
  }
}
