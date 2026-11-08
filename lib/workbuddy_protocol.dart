// Supplier-only wire conversions, adapted from magpie-community WorkBuddy
// 0.2.25 (MIT). No client identity rewording, history relocation or retries.
import 'dart:convert';
import 'model_provider.dart';

class WorkBuddyModelSpec {
  WorkBuddyModelSpec(Map row, {required bool messages}) {
    reasoning = row['supportsReasoning'] is bool
        ? row['supportsReasoning']
        : null;
    final configuration = row['reasoning'];
    final r = configuration is Map ? configuration : const {};
    if (r['supportedEfforts'] is List)
      efforts = (r['supportedEfforts'] as List)
          .whereType<String>()
          .toSet()
          .toList();
    if (efforts.isEmpty && row['supportsReasoning'] == true) {
      final own = r['effort'];
      efforts = [
        for (final e in ['low', 'medium', 'high', 'xhigh', 'max'])
          if (['low', 'high', 'max', own].contains(e)) e,
      ];
    }
    if (messages && efforts.isNotEmpty && !efforts.contains('max'))
      efforts.add('max');
    if (reasoning == null &&
        (efforts.isNotEmpty || row['onlyReasoning'] == true))
      reasoning = true;
    final off =
        row['onlyReasoning'] != true && r['canDisableThinking'] != false ||
        {'deepseek-v4.1-flash', 'deepseek-v4.1-flash-sg'}.contains(row['id']);
    alwaysThinks = reasoning == true && !off;
    final own = r['defaultEffort'] ?? r['effort'];
    if (own is String && efforts.contains(own)) defaultEffort = own;
    if (off && efforts.isNotEmpty && !efforts.contains('none'))
      efforts.insert(0, 'none');
  }
  List<String> efforts = [];
  String? defaultEffort;
  bool alwaysThinks = false;
  bool? reasoning;
}

const _types = {
  'string',
  'number',
  'integer',
  'boolean',
  'object',
  'array',
  'null',
};
const _single = [
  'items',
  'additionalItems',
  'unevaluatedItems',
  'contains',
  'not',
  'if',
  'then',
  'else',
  'propertyNames',
  'additionalProperties',
  'unevaluatedProperties',
];
const _lists = ['anyOf', 'oneOf', 'allOf', 'prefixItems'];
const _maps = [
  'properties',
  'patternProperties',
  r'$defs',
  'definitions',
  'dependentSchemas',
];

Future<ModelReply> workBuddyFailure(ModelReply reply) async {
  if (reply.status >= 200 && reply.status < 300) return reply;
  final bytes = <int>[];
  await for (final chunk in reply.body) {
    if (bytes.length + chunk.length > 2 * 1024 * 1024)
      throw const ModelServiceFailure('response_too_large');
    bytes.addAll(chunk);
  }
  final text = utf8.decode(bytes, allowMalformed: true);
  dynamic value;
  try {
    value = jsonDecode(text);
  } catch (_) {}
  final error = value is Map && value['error'] is Map
      ? value['error'] as Map
      : value is Map
      ? value
      : const {};
  final codes = [
    error['internal_code'],
    error['code'],
    if (error['data'] is Map) error['data']['code'],
  ].map((c) => '$c').toSet();
  final String code;
  if (codes.contains('14018') ||
      RegExp(r'credits exhausted|额度已用尽', caseSensitive: false).hasMatch(text)) {
    code = 'quota_exhausted';
  } else if (codes.contains('11140')) {
    code = 'account_restricted';
  } else if (codes.contains('11159') ||
      RegExp(
        r'thinking_signature_invalid|invalid.*signature.*thinking',
        caseSensitive: false,
      ).hasMatch(text)) {
    code = 'invalid_thinking_signature';
  } else if (RegExp(
    r'prompt is too long|context_length_exceeded',
    caseSensitive: false,
  ).hasMatch(text)) {
    code = 'context_length_exceeded';
  } else if (reply.status == 401) {
    code = 'authentication_required';
  } else if (reply.status == 429) {
    code = 'upstream_rate_limited';
  } else {
    code = 'upstream_rejected';
  }
  return ModelReply(
    reply.status >= 400 && reply.status <= 599 ? reply.status : 502,
    'application/json',
    Stream.value(
      utf8.encode(
        jsonEncode({
          'error': {'type': code, 'message': code},
        }),
      ),
    ),
    cancel: reply.cancel,
    errorCode: code,
    retryAfterSeconds: reply.retryAfterSeconds,
    credentialRejected: reply.credentialRejected,
  );
}

String _valueType(Object? v) => v == null
    ? 'null'
    : v is List
    ? 'array'
    : v is Map
    ? 'object'
    : v is bool
    ? 'boolean'
    : v is num
    ? v % 1 == 0
          ? 'integer'
          : 'number'
    : 'string';

Map<String, dynamic> _fitParameters(Object? value) {
  if (value is! Map)
    return {'type': 'object', 'properties': <String, dynamic>{}};
  var root = Map<String, dynamic>.from(value);
  Object? resolve(Object? branch) {
    if (branch is! Map) return branch;
    final ref = branch[r'$ref'];
    if (ref is! String || !ref.startsWith('#/')) return branch;
    Object? found = root;
    for (final segment in ref.substring(2).split('/')) {
      found = found is Map
          ? found[segment.replaceAll('~1', '/').replaceAll('~0', '~')]
          : null;
    }
    return found is Map ? found : branch;
  }

  bool object(Object? branch, [Set<String> seen = const {}]) {
    if (branch is! Map) return false;
    if (branch.containsKey('type')) return branch['type'] == 'object';
    final ref = branch[r'$ref'];
    if (ref is! String || seen.contains(ref) || seen.length > 16) return false;
    final target = resolve(branch);
    return !identical(target, branch) && object(target, {...seen, ref});
  }

  Object? fit(Object? value, String keyword, int depth) {
    if (depth > 64) throw const ModelServiceFailure('unsupported_tool_schema');
    if (value is bool)
      return {'additionalProperties', 'unevaluatedProperties'}.contains(keyword)
          ? value
          : value
          ? <String, dynamic>{}
          : {'not': <String, dynamic>{}};
    if (value is! Map) return value;
    final s = Map<String, dynamic>.from(value);
    if (s.containsKey('type')) {
      final types = (s['type'] is List ? s['type'] as List : [s['type']])
          .whereType<String>()
          .map((t) => t.toLowerCase())
          .where(_types.contains)
          .toSet()
          .toList();
      if (types.isEmpty) {
        s.remove('type');
      } else {
        s['type'] = types.length == 1 ? types.single : types;
      }
    }
    if (s.containsKey('required')) {
      if (s['required'] is List) {
        s['required'] = (s['required'] as List).whereType<String>().toList();
      } else {
        s.remove('required');
      }
    }
    if (s['pattern'] is String)
      s['pattern'] = (s['pattern'] as String).replaceAllMapped(
        RegExp(r'\\\\|\\0(?![0-9])'),
        (m) => m[0] == r'\\' ? m[0]! : r'\u0000',
      );
    if (s['items'] is List) {
      final items = (s['items'] as List).whereType<Map>().toList();
      s['items'] = items.isEmpty
          ? <String, dynamic>{}
          : items.length == 1
          ? items.single
          : {'anyOf': items};
      s.remove('additionalItems');
    }
    if (s.containsKey('enum')) {
      final values = s['enum'];
      if (values is! List || values.isEmpty) {
        s.remove('enum');
      } else {
        final listed = s['type'] is List ? s['type'] as List : [s['type']];
        if (listed.where((t) => t != null && t != 'null').length != 1) {
          final byType = <String, List<dynamic>>{};
          for (final v in values) {
            byType.putIfAbsent(_valueType(v), () => []).add(v);
          }
          if (byType.containsKey('number') && byType.containsKey('integer'))
            byType['number']!.addAll(byType.remove('integer')!);
          final nullable = byType.remove('null') != null;
          if (byType.length <= 1) {
            final type = byType.keys.firstOrNull;
            s['type'] = type == null
                ? 'null'
                : nullable
                ? [type, 'null']
                : type;
          } else {
            final union = [
              for (final entry in byType.entries)
                {'type': entry.key, 'enum': entry.value},
              if (nullable) {'type': 'null'},
            ];
            s.remove('enum');
            s.remove('type');
            if (s['anyOf'] is List) {
              s['allOf'] = [
                ...?s['allOf'] as List?,
                {'anyOf': union},
              ];
            } else {
              s['anyOf'] = union;
            }
          }
        }
      }
    }
    final union = s['oneOf'];
    if (!s.containsKey('type') &&
        union is List &&
        union.isNotEmpty &&
        union.every(object))
      s['type'] = 'object';
    for (final key in _single) {
      if (s.containsKey(key)) s[key] = fit(s[key], key, depth + 1);
    }
    for (final key in _lists) {
      if (s[key] is List)
        s[key] = [for (final child in s[key]) fit(child, key, depth + 1)];
    }
    for (final key in _maps) {
      if (s[key] is Map)
        s[key] = {
          for (final entry in (s[key] as Map).entries)
            entry.key: fit(entry.value, key, depth + 1),
        };
    }
    return s;
  }

  Map<String, dynamic> objectRoot(Map value, [int depth = 0]) {
    if (depth > 8) throw const ModelServiceFailure('unsupported_tool_schema');
    final s = Map<String, dynamic>.from(value);
    final props = <String, dynamic>{
      if (s['properties'] is Map) ...Map<String, dynamic>.from(s['properties']),
    };
    final required = <String>{
      if (s['required'] is List) ...(s['required'] as List).whereType<String>(),
    };
    Map? branch(Object? value) {
      final b = resolve(value);
      if (b is! Map) return null;
      return ['allOf', 'anyOf', 'oneOf'].any((k) => b[k] is List)
          ? objectRoot(b, depth + 1)
          : b;
    }

    if (s['allOf'] is List)
      for (final raw in s['allOf']) {
        final b = branch(raw);
        if (b == null) continue;
        if (b['properties'] is Map)
          for (final entry in (b['properties'] as Map).entries) {
            props.putIfAbsent(entry.key, () => entry.value);
          }
        if (b['required'] is List)
          required.addAll((b['required'] as List).whereType<String>());
      }
    final alternatives = <Map>[];
    for (final key in ['anyOf', 'oneOf']) {
      if (s[key] is! List) continue;
      for (final raw in s[key]) {
        final b = branch(raw);
        if (b != null && (b['type'] == 'object' || b['properties'] is Map))
          alternatives.add(b);
      }
    }
    final collected = <String, List<dynamic>>{};
    for (final b in alternatives) {
      if (b['properties'] is! Map) continue;
      for (final entry in (b['properties'] as Map).entries) {
        if (props.containsKey(entry.key)) continue;
        final list = collected.putIfAbsent(entry.key, () => []);
        if (!list.any((v) => jsonEncode(v) == jsonEncode(entry.value)))
          list.add(entry.value);
      }
    }
    for (final entry in collected.entries) {
      props[entry.key] = entry.value.length == 1
          ? entry.value.single
          : {'anyOf': entry.value};
    }
    if (alternatives.isNotEmpty && alternatives.first['properties'] is Map)
      for (final key in (alternatives.first['properties'] as Map).keys) {
        if (key is String &&
            alternatives.every(
              (b) =>
                  b['required'] is List &&
                  (b['required'] as List).contains(key),
            ))
          required.add(key);
      }
    s.remove('allOf');
    s.remove('anyOf');
    s.remove('oneOf');
    s['type'] = 'object';
    s['properties'] = props;
    final req = required.where(props.containsKey).toList();
    if (req.isEmpty) {
      s.remove('required');
    } else {
      s['required'] = req;
    }
    return s;
  }

  root = Map<String, dynamic>.from(fit(root, '', 0) as Map);
  return objectRoot(root);
}

class WorkBuddyChat {
  WorkBuddyChat(Map<String, dynamic> input, {String? defaultEffort})
    : body = Map<String, dynamic>.from(jsonDecode(jsonEncode(input))) {
    final messages = body['messages'];
    if (messages is! List) throw const ModelServiceFailure('invalid_request');
    if (body.containsKey('max_completion_tokens')) {
      body.putIfAbsent('max_tokens', () => body['max_completion_tokens']);
      body.remove('max_completion_tokens');
    }
    for (final m in messages) {
      if (m is! Map) throw const ModelServiceFailure('invalid_request');
      if (m['role'] == 'developer') m['role'] = 'system';
      if (m['role'] != 'assistant') continue;
      var thought = m['reasoning_content'];
      if ((thought is! String || thought.isEmpty) &&
          m['reasoning_details'] is List)
        thought = (m['reasoning_details'] as List)
            .whereType<Map>()
            .map(
              (d) => d['text'] is String
                  ? d['text']
                  : d['summary'] is String
                  ? d['summary']
                  : '',
            )
            .join();
      if (thought is String &&
          thought.isNotEmpty &&
          (m['reasoning'] is! String || (m['reasoning'] as String).isEmpty))
        m['reasoning'] = thought;
      m.remove('reasoning_content');
      m.remove('reasoning_details');
    }
    if (messages.isNotEmpty && messages.first['role'] != 'system')
      messages.insert(0, {
        'role': 'system',
        'content': 'You are a helpful assistant.',
      });
    final budget = body['max_tokens'];
    if (!body.containsKey('reasoning_effort') &&
        !(body['reasoning'] is Map && body['reasoning']['effort'] != null) &&
        !(budget is num && budget > 0 && budget <= 1024) &&
        defaultEffort != null)
      body['reasoning_effort'] = defaultEffort;
    final theirs = <String, String>{};
    final declared = body['tools'];
    if (declared is List) {
      final safe = RegExp(r'^[A-Za-z0-9_-]+$');
      final taken = <String>{
        for (final t in declared)
          if (t is Map &&
              t['function'] is Map &&
              t['function']['name'] is String &&
              safe.hasMatch(t['function']['name']))
            t['function']['name'],
      };
      for (final t in declared) {
        if (t is! Map || t['function'] is! Map) continue;
        final fn = t['function'] as Map;
        final original = fn['name'];
        if (original is String && !safe.hasMatch(original)) {
          final base = original.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
          var name = base;
          for (var suffix = 2; taken.contains(name); suffix++) {
            name = '${base}_$suffix';
          }
          taken.add(name);
          names[name] = original;
          theirs[original] = name;
          fn['name'] = name;
        }
        if (fn.containsKey('parameters'))
          fn['parameters'] = _fitParameters(fn['parameters']);
      }
    }
    for (final m in messages.whereType<Map>()) {
      if (m['tool_calls'] is List)
        for (final call in m['tool_calls']) {
          if (call is Map &&
              call['function'] is Map &&
              theirs.containsKey(call['function']['name']))
            call['function']['name'] = theirs[call['function']['name']];
        }
      if (m['role'] == 'tool' && theirs.containsKey(m['name']))
        m['name'] = theirs[m['name']];
    }
    var choice = body['tool_choice'];
    if (choice is Map) {
      final type = choice['type'];
      final name = choice['function'] is Map
          ? choice['function']['name']
          : null;
      choice = type == 'function' && name is String
          ? theirs[name] ?? name
          : {'none', 'auto', 'required'}.contains(type)
          ? type
          : null;
      if (choice == null) {
        body.remove('tool_choice');
      } else {
        body['tool_choice'] = choice;
      }
    }
    if (choice == 'none') {
      body.remove('tool_choice');
      body.remove('tools');
      body.remove('functions');
    }
  }
  final Map<String, dynamic> body;
  final names = <String, String>{};

  void _restoreNames(Object? value) {
    if (value is! Map || value['choices'] is! List) return;
    for (final choice in value['choices']) {
      if (choice is! Map) continue;
      for (final key in ['message', 'delta']) {
        final message = choice[key];
        if (message is! Map || message['tool_calls'] is! List) continue;
        for (final call in message['tool_calls']) {
          if (call is! Map || call['function'] is! Map) continue;
          final fn = call['function'] as Map;
          if (names.containsKey(fn['name'])) fn['name'] = names[fn['name']];
        }
      }
    }
  }

  Future<ModelReply> restoreReply(ModelReply reply) async {
    if (names.isEmpty || reply.status != 200) return reply;
    Stream<List<int>> converted() async* {
      if (reply.contentType.contains('text/event-stream')) {
        await for (var line
            in utf8.decoder.bind(reply.body).transform(const LineSplitter())) {
          if (line.length > 2 * 1024 * 1024)
            throw const ModelServiceFailure('response_too_large');
          if (line.startsWith('data:') &&
              line.substring(5).trim() != '[DONE]') {
            try {
              final value = jsonDecode(line.substring(5).trim());
              _restoreNames(value);
              line = 'data: ${jsonEncode(value)}';
            } catch (_) {}
          }
          yield utf8.encode('$line\n');
        }
      } else {
        final bytes = <int>[];
        await for (final chunk in reply.body) {
          if (bytes.length + chunk.length > 2 * 1024 * 1024)
            throw const ModelServiceFailure('response_too_large');
          bytes.addAll(chunk);
        }
        final value = jsonDecode(utf8.decode(bytes));
        _restoreNames(value);
        yield utf8.encode(jsonEncode(value));
      }
    }

    return ModelReply(
      reply.status,
      reply.contentType,
      converted(),
      cancel: reply.cancel,
      errorCode: reply.errorCode,
      retryAfterSeconds: reply.retryAfterSeconds,
      credentialRejected: reply.credentialRejected,
    );
  }
}
