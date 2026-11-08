import 'dart:convert';
import 'dart:io';

import '../lib/model_messages.dart';
import '../lib/model_provider.dart';

Object? ordered(Object? value) {
  if (value is Map) {
    return {
      for (final key in value.keys.cast<String>().toList()..sort())
        key: ordered(value[key]),
    };
  }
  if (value is List) return value.map(ordered).toList();
  return value;
}

void expectJson(Object? actual, String expected) {
  if (jsonEncode(ordered(actual)) !=
      jsonEncode(ordered(jsonDecode(expected)))) {
    throw StateError('transformed payload differs: ${jsonEncode(actual)}');
  }
}

Map<String, dynamic> convert(String fixture) {
  final body = jsonDecode(fixture) as Map<String, dynamic>;
  final original = jsonEncode(body);
  try {
    return messagesToChat(body, 'shared-model');
  } finally {
    if (jsonEncode(body) != original) throw StateError('caller body mutated');
  }
}

void reject(String fixture) {
  try {
    convert(fixture);
  } on ModelServiceFailure catch (failure) {
    if (failure.code == 'unsupported_content' ||
        failure.code == 'unsupported_request_parameter') {
      return;
    }
    rethrow;
  }
  throw StateError('unsupported shape was accepted');
}

void main() {
  var passed = 0, failed = 0;
  void scenario(String name, void Function() check) {
    try {
      check();
      passed++;
      stdout.writeln('PASS $name');
    } catch (failure) {
      failed++;
      stdout.writeln('FAIL $name: $failure');
    }
  }

  scenario(
    'inline declarations join current tools without losing system text',
    () {
      final wire = convert(r'''{
      "system":"Root rules.",
      "tools":[{"name":"Read","description":"current","input_schema":{"type":"object","properties":{"path":{"type":"string"}}}}],
      "messages":[
        {"role":"user","content":"Use tools."},
        {"role":"system","content":[{"type":"tool_addition","tool":{"type":"tool_definition","definition":{"name":"Write","input_schema":{"type":"object"}}}}]},
        {"role":"system","content":[
          {"type":"text","text":"Environment kept\n"},
          {"type":"tool_addition","tool":{"type":"tool_definition","definition":{"name":"Read","description":"old","input_schema":{"type":"object"}}}},
          {"type":"tool_addition","tool":{"type":"tool_reference","name":"Read"}},
          {"type":"text","text":"cwd kept"}
        ]},
        {"role":"user","content":[{"type":"tool_definition","definition":{"name":"Grep","input_schema":{"type":"object"}}},{"type":"text","text":"Continue."}]}
      ]
    }''');
      expectJson(wire['tools'], r'''[
      {"type":"function","function":{"name":"Read","description":"current","parameters":{"type":"object","properties":{"path":{"type":"string"}}}}},
      {"type":"function","function":{"name":"Write","parameters":{"type":"object"}}},
      {"type":"function","function":{"name":"Grep","parameters":{"type":"object"}}}
    ]''');
      expectJson(wire['messages'], r'''[
      {"role":"system","content":"Root rules."},
      {"role":"user","content":"Use tools."},
      {"role":"system","content":"Environment kept\ncwd kept"},
      {"role":"user","content":"Continue."}
    ]''');
    },
  );

  scenario(
    'nested definitions retain search result IDs and named tool meaning',
    () {
      final wire = convert(r'''{
      "tools":[{"name":"ToolSearch","input_schema":{"type":"object"}},{"name":"Read","description":"current","input_schema":{"type":"object"}}],
      "messages":[
        {"role":"user","content":"Load a writer and reader."},
        {"role":"assistant","content":[{"type":"tool_use","id":"search-1","name":"ToolSearch","input":{"query":"select:Write,Read"}}]},
        {"role":"user","content":[{"type":"tool_result","tool_use_id":"search-1","content":[
          {"type":"text","text":"Loaded:\n"},
          {"type":"tool_definition","definition":{"name":"Read","description":"stale","input_schema":{"type":"object"}}},
          {"type":"tool_definition","definition":{"name":"Write","input_schema":{"type":"object"}}},
          {"type":"tool_reference","tool_name":"Read"}
        ]}]}
      ]
    }''');
      expectJson(wire['tools'], r'''[
      {"type":"function","function":{"name":"ToolSearch","parameters":{"type":"object"}}},
      {"type":"function","function":{"name":"Read","description":"current","parameters":{"type":"object"}}},
      {"type":"function","function":{"name":"Write","parameters":{"type":"object"}}}
    ]''');
      expectJson(wire['messages'], r'''[
      {"role":"user","content":"Load a writer and reader."},
      {"role":"assistant","content":null,"tool_calls":[{"id":"search-1","type":"function","function":{"name":"ToolSearch","arguments":"{\"query\":\"select:Write,Read\"}"}}]},
      {"role":"tool","tool_call_id":"search-1","content":"Loaded:\nTool Read is loaded and can be called now.\nTool Write is loaded and can be called now.\nTool Read is loaded and can be called now."}
    ]''');
    },
  );

  scenario('old normal ToolSearch references still load declared tools', () {
    final wire = convert(r'''{
      "tools":[{"name":"Read","input_schema":{"type":"object"}},{"name":"DeferredToolPlaceholder","input_schema":{"type":"object"},"defer_loading":true}],
      "messages":[
        {"role":"assistant","content":[{"type":"tool_use","id":"search-old","name":"ToolSearch","input":{}}]},
        {"role":"user","content":[{"type":"tool_result","tool_use_id":"search-old","content":[{"type":"tool_reference","tool_name":"Read"}]}]}
      ]
    }''');
    expectJson(
      wire['tools'],
      r'''[{"type":"function","function":{"name":"Read","parameters":{"type":"object"}}}]''',
    );
    expectJson(
      (wire['messages'] as List).last,
      r'''{"role":"tool","tool_call_id":"search-old","content":"Tool Read is loaded and can be called now."}''',
    );
  });

  scenario(
    'removal retires inline-only tools while current declarations win',
    () {
      final wire = convert(r'''{
      "tools":[{"name":"Read","input_schema":{"type":"object"}}],
      "messages":[
        {"role":"user","content":"Keep my text."},
        {"role":"system","content":[{"type":"tool_addition","tool":{"type":"tool_definition","definition":{"name":"Write","input_schema":{"type":"object"}}}}]},
        {"role":"system","content":[{"type":"tool_removal","tool":{"type":"tool_reference","name":"Read"}}]},
        {"role":"system","content":[{"type":"text","text":"Before removal.\n"},{"type":"tool_removal","tool":{"type":"tool_reference","name":"Write"}},{"type":"text","text":"\nAfter removal."}]}
      ]
    }''');
      expectJson(
        wire['tools'],
        r'''[{"type":"function","function":{"name":"Read","parameters":{"type":"object"}}}]''',
      );
      expectJson(wire['messages'], r'''[
      {"role":"user","content":"Keep my text."},
      {"role":"system","content":"Before removal.\nTool Write is no longer available.\nAfter removal."}
    ]''');
    },
  );

  scenario('named re-addition restores a previously declared inline tool', () {
    final wire = convert(r'''{"messages":[
      {"role":"system","content":[{"type":"tool_addition","tool":{"type":"tool_definition","definition":{"name":"Read","input_schema":{"type":"object"}}}}]},
      {"role":"system","content":[{"type":"tool_removal","tool":{"type":"tool_reference","name":"Read"}}]},
      {"role":"system","content":[{"type":"tool_addition","tool":{"type":"tool_reference","name":"Read"}}]},
      {"role":"user","content":"Read now."}
    ]}''');
    expectJson(
      wire['tools'],
      r'''[{"type":"function","function":{"name":"Read","parameters":{"type":"object"}}}]''',
    );
    expectJson(wire['messages'], r'''[
      {"role":"system","content":"Tool Read is no longer available."},
      {"role":"system","content":"Tool Read is loaded and can be called now."},
      {"role":"user","content":"Read now."}
    ]''');
  });

  scenario(
    'multiple image results keep tool pairing before attributed user images',
    () {
      final wire = convert(r'''{"messages":[
      {"role":"assistant","content":[
        {"type":"tool_use","id":"image-a","name":"Screenshot","input":{}},
        {"type":"tool_use","id":"image-b","name":"Camera","input":{}}
      ]},
      {"role":"user","content":[
        {"type":"text","text":"Before results."},
        {"type":"tool_result","tool_use_id":"image-a","content":[{"type":"text","text":"A caption"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AA=="}}]},
        {"type":"text","text":"Between results."},
        {"type":"tool_result","tool_use_id":"image-b","content":[{"type":"image","source":{"type":"url","url":"https://example.invalid/b.png"}}]},
        {"type":"text","text":"After results."}
      ]}
    ]}''');
      expectJson(wire['messages'], r'''[
      {"role":"assistant","content":null,"tool_calls":[
        {"id":"image-a","type":"function","function":{"name":"Screenshot","arguments":"{}"}},
        {"id":"image-b","type":"function","function":{"name":"Camera","arguments":"{}"}}
      ]},
      {"role":"tool","tool_call_id":"image-a","content":"A caption\n\n[The tool returned an image; it follows in the next message.]"},
      {"role":"tool","tool_call_id":"image-b","content":"[The tool returned an image; it follows in the next message.]"},
      {"role":"user","content":[
        {"type":"text","text":"[From the result of Screenshot (tool call image-a):]"},
        {"type":"image_url","image_url":{"url":"data:image/png;base64,AA=="}},
        {"type":"text","text":"[From the result of Camera (tool call image-b):]"},
        {"type":"image_url","image_url":{"url":"https://example.invalid/b.png"}},
        {"type":"text","text":"Before results."},
        {"type":"text","text":"Between results."},
        {"type":"text","text":"After results."}
      ]}
    ]''');
    },
  );

  scenario('split image results merge into the next user message', () {
    final wire = convert(r'''{"messages":[
      {"role":"assistant","content":[{"type":"tool_use","id":"a","name":"Read","input":{}},{"type":"tool_use","id":"b","name":"Read","input":{}}]},
      {"role":"user","content":[{"type":"tool_result","tool_use_id":"a","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AA=="}}]}]},
      {"role":"user","content":[{"type":"tool_result","tool_use_id":"b","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"BB=="}}]}]},
      {"role":"user","content":"Explain both."}
    ]}''');
    expectJson(
      (wire['messages'] as List).map((m) => m['role']).toList(),
      '["assistant","tool","tool","user"]',
    );
    expectJson((wire['messages'] as List).last, r'''{"role":"user","content":[
      {"type":"text","text":"[From the result of Read (tool call a):]"},
      {"type":"image_url","image_url":{"url":"data:image/png;base64,AA=="}},
      {"type":"text","text":"[From the result of Read (tool call b):]"},
      {"type":"image_url","image_url":{"url":"data:image/png;base64,BB=="}},
      {"type":"text","text":"Explain both."}
    ]}''');
  });

  scenario(
    'image results flush before assistant turns and retain error text',
    () {
      final wire = convert(r'''{"messages":[
      {"role":"assistant","content":[{"type":"tool_use","id":"a","name":"Capture","input":{}}]},
      {"role":"user","content":[{"type":"tool_result","tool_use_id":"a","is_error":true,"content":[{"type":"text","text":"Partial failure"},{"type":"image","source":{"type":"url","url":"https://example.invalid/a.png"}}]}]},
      {"role":"assistant","content":"I see the failure."}
    ]}''');
      final messages = wire['messages'] as List;
      expectJson(
        messages.map((m) => m['role']).toList(),
        '["assistant","tool","user","assistant"]',
      );
      expectJson(jsonDecode(messages[1]['content'] as String), r'''{
      "is_error":true,
      "content":"Partial failure\n\n[The tool returned an image; it follows in the next message.]"
    }''');
      expectJson(messages[2], r'''{"role":"user","content":[
      {"type":"text","text":"[From the result of Capture (tool call a):]"},
      {"type":"image_url","image_url":{"url":"https://example.invalid/a.png"}}
    ]}''');
    },
  );

  scenario(
    'split parallel results keep accompanying user text after both tools',
    () {
      final wire = convert(r'''{"messages":[
      {"role":"assistant","content":[{"type":"tool_use","id":"a","name":"Read","input":{}},{"type":"tool_use","id":"b","name":"Read","input":{}}]},
      {"role":"user","content":[{"type":"text","text":"First note."},{"type":"tool_result","tool_use_id":"a","content":[{"type":"image","source":{"type":"url","url":"https://example.invalid/a.png"}}]}]},
      {"role":"user","content":[{"type":"text","text":"Second note."},{"type":"tool_result","tool_use_id":"b","content":"Second result."}]}
    ]}''');
      final messages = wire['messages'] as List;
      expectJson(
        messages.map((m) => m['role']).toList(),
        '["assistant","tool","tool","user"]',
      );
      expectJson(messages.last, r'''{"role":"user","content":[
      {"type":"text","text":"[From the result of Read (tool call a):]"},
      {"type":"image_url","image_url":{"url":"https://example.invalid/a.png"}},
      {"type":"text","text":"First note."},
      {"type":"text","text":"Second note."}
    ]}''');
    },
  );

  scenario('invalid roles cannot hide inside metadata-only messages', () {
    reject(
      r'''{"messages":[{"role":"unknown","content":[{"type":"tool_definition","definition":{"name":"Read","input_schema":{"type":"object"}}}]}]}''',
    );
  });

  scenario('forced tool choice cannot revive a removed inline declaration', () {
    reject(r'''{"tool_choice":{"type":"tool","name":"Read"},"messages":[
      {"role":"system","content":[{"type":"tool_addition","tool":{"type":"tool_definition","definition":{"name":"Read","input_schema":{"type":"object"}}}}]},
      {"role":"system","content":[{"type":"tool_removal","tool":{"type":"tool_reference","name":"Read"}}]},
      {"role":"user","content":"Continue."}
    ]}''');
  });

  scenario('malformed loading actions, unknown tools and invalid images reject', () {
    for (final fixture in [
      r'''{"messages":[{"role":"system","content":[{"type":"tool_addition","tool":{"type":"tool_definition","definition":{"input_schema":{"type":"object"}}}}]}]}''',
      r'''{"messages":[{"role":"system","content":[{"type":"tool_definition","definition":{"name":"Read"}}]}]}''',
      r'''{"messages":[{"role":"system","content":[{"type":"tool_addition","tool":{"type":"tool_reference","name":"unknown"}}]}]}''',
      r'''{"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"s","content":[{"type":"tool_reference","tool_name":""}]}]}]}''',
      r'''{"messages":[{"role":"system","content":[{"type":"tool_removal","tool":{"type":"tool_reference","name":"unknown"}}]}]}''',
      r'''{"tools":[{"name":"Read","input_schema":{"type":"object"}}],"messages":[{"role":"system","content":[{"type":"tool_removal","name":"Read"}]}]}''',
      r'''{"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"i","content":[{"type":"image","source":{"type":"url"}}]}]}]}''',
      r'''{"tools":[{"name":"Read","description":42,"input_schema":{"type":"object"}}],"messages":[{"role":"user","content":"hi"}]}''',
      r'''{"tools":[{"name":"Read","defer_loading":"yes","input_schema":{"type":"object"}}],"messages":[{"role":"user","content":"hi"}]}''',
      r'''{"tools":[{"name":"Read","input_schema":{"type":"object"}}],"messages":[{"role":"system","content":[{"type":"tool_removal","tool":{"type":"tool_reference","name":"Read","tool_name":"Write"}}]}]}''',
    ]) {
      reject(fixture);
    }
  });

  scenario(
    'signed reasoning and destructive context remain explicit rejections',
    () {
      reject(
        r'''{"messages":[{"role":"assistant","content":[{"type":"thinking","thinking":"prior","signature":"signed-value"}]}]}''',
      );
      reject(
        r'''{"messages":[{"role":"user","content":"hi"}],"context_management":{"edits":[{"type":"clear_thinking_20251015","keep":{"type":"thinking_turns","value":1}}]}}''',
      );
    },
  );

  stdout.writeln('RESULT $passed passed; $failed failed');
  if (failed > 0) exitCode = 1;
}
