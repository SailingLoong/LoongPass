import 'dart:convert';

import '../lib/model_messages.dart';
import '../lib/model_provider.dart';
import '../lib/model_sse.dart';

void check(bool value, String why) {
  if (!value) throw StateError(why);
}

Future<void> main() async {
  final body = <String, dynamic>{
    'model': 'glm-5.3-flash',
    'max_tokens': 256,
    'stream': true,
    'system': 'Keep this exact system prompt.',
    'messages': [
      {'role': 'user', 'content': 'Use echo.'},
      {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Checking.'},
          {
            'type': 'tool_use',
            'id': 'call-1',
            'name': 'echo',
            'input': {'marker': '你好'},
          },
        ],
      },
      {
        'role': 'user',
        'content': [
          {'type': 'tool_result', 'tool_use_id': 'call-1', 'content': '你好'},
          {'type': 'text', 'text': 'Continue.'},
        ],
      },
    ],
    'tools': [
      {
        'name': 'echo',
        'description': 'Echo marker',
        'input_schema': {'type': 'object'},
      },
    ],
    'tool_choice': {
      'type': 'tool',
      'name': 'echo',
      'disable_parallel_tool_use': true,
    },
    'stop_sequences': ['END'],
  };
  final original = jsonEncode(body);
  final wire = messagesToChat(body, 'GLM-5.3-Flash');
  check(jsonEncode(body) == original, 'caller body mutated');
  check(
    wire['model'] == 'GLM-5.3-Flash' && wire['max_tokens'] == 256,
    'target ID or limit changed',
  );
  final messages = wire['messages'] as List;
  check(messages.first['content'] == body['system'], 'system prompt lost');
  check(messages[2]['tool_calls'][0]['id'] == 'call-1', 'tool identity lost');
  check(
    jsonDecode(
          messages[2]['tool_calls'][0]['function']['arguments'],
        )['marker'] ==
        '你好',
    'tool input lost',
  );
  check(
    messages[3]['role'] == 'tool' &&
        messages[3]['content'] == '你好' &&
        messages[4]['content'] == 'Continue.',
    'tool result ordering lost',
  );
  check(
    wire['tools'][0]['function']['parameters']['type'] == 'object',
    'tool schema lost',
  );
  check(
    wire['tool_choice']['function']['name'] == 'echo' &&
        wire['parallel_tool_calls'] == false,
    'forced tool lost',
  );
  check(wire['stop'][0] == 'END', 'stop sequence lost');
  // Normal Claude Code sessions carry environment updates as system messages
  // inside the transcript, alongside the request's top-level system prompt.
  final withEnvironment = <String, dynamic>{
    ...body,
    'messages': [
      {'role': 'user', 'content': 'hello'},
      {
        'role': 'system',
        'content': [
          {'type': 'text', 'text': '# Environment\nPlatform: darwin'},
        ],
      },
      {'role': 'assistant', 'content': 'Hello.'},
      {'role': 'system', 'content': 'Updated environment.'},
      ...body['messages'] as List,
    ],
  };
  final environmentOriginal = jsonEncode(withEnvironment);
  final environmentWire = messagesToChat(withEnvironment, 'deepseek-v4-flash');
  check(
    jsonEncode((environmentWire['messages'] as List).take(5).toList()) ==
            jsonEncode([
              {'role': 'system', 'content': 'Keep this exact system prompt.'},
              {'role': 'user', 'content': 'hello'},
              {'role': 'system', 'content': '# Environment\nPlatform: darwin'},
              {'role': 'assistant', 'content': 'Hello.'},
              {'role': 'system', 'content': 'Updated environment.'},
            ]) &&
        jsonEncode(withEnvironment) == environmentOriginal,
    'inline system updates must retain their role, content and transcript order',
  );
  final nativeClient = messagesToChat({
    ...body,
    'thinking': {'type': 'adaptive', 'display': 'omitted'},
    'output_config': {'effort': 'high'},
    'context_management': {
      'edits': [
        {'type': 'clear_thinking_20251015', 'keep': 'all'},
      ],
    },
  }, 'GLM-5.3-Flash');
  check(
    nativeClient['reasoning_effort'] == 'high' &&
        jsonEncode(nativeClient['messages']) == jsonEncode(wire['messages']),
    'native Claude Code effort or preserve-all history changed',
  );
  final continued = messagesToChat({
    ...body,
    'messages': [
      {
        'role': 'assistant',
        'content': [
          {'type': 'thinking', 'thinking': 'Prior reasoning', 'signature': ''},
          {
            'type': 'tool_use',
            'id': 'call-kept',
            'name': 'echo',
            'input': {'marker': 'kept'},
          },
        ],
      },
      {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'call-kept',
            'content': 'kept',
          },
        ],
      },
    ],
  }, 'GLM-5.3-Flash');
  check(
    continued['messages'][1]['reasoning_content'] == 'Prior reasoning' &&
        continued['messages'][2]['tool_call_id'] == 'call-kept',
    'empty native thinking signature rejected or tool pair changed',
  );
  final loaded = messagesToChat({
    ...body,
    'tools': [
      ...(body['tools'] as List),
      {
        'name': 'DeferredToolPlaceholder',
        'input_schema': {'type': 'object'},
        'defer_loading': true,
      },
    ],
    'messages': [
      {'role': 'user', 'content': 'Load echo.'},
      {
        'role': 'assistant',
        'content': [
          {
            'type': 'tool_use',
            'id': 'search-1',
            'name': 'ToolSearch',
            'input': {},
          },
        ],
      },
      {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'search-1',
            'content': [
              {'type': 'tool_reference', 'tool_name': 'echo'},
            ],
          },
        ],
      },
    ],
  }, 'm');
  check(
    loaded['messages'][3]['role'] == 'tool' &&
        loaded['messages'][3]['tool_call_id'] == 'search-1' &&
        loaded['messages'][3]['content'] ==
            'Tool echo is loaded and can be called now.' &&
        (loaded['tools'] as List).length == 1,
    'deferred tool load must retain the named result without offering its placeholder',
  );
  final title = messagesToChat({
    ...body,
    'output_config': {'effort': 'high'},
  }, 'm');
  check(
    !title.containsKey('reasoning_effort'),
    'effort without requested thinking must not enable reasoning',
  );
  for (final entry in {
    4096: 'low',
    12000: 'medium',
    24000: 'high',
    32000: 'xhigh',
  }.entries) {
    final budget = messagesToChat({
      ...body,
      'max_tokens': 65536,
      'thinking': {'type': 'enabled', 'budget_tokens': entry.key},
    }, 'm');
    check(
      budget['reasoning_effort'] == entry.value,
      'standard Claude thinking budget did not preserve its effort',
    );
  }
  final structured = messagesToChat({
    ...body,
    'output_config': {
      'format': {
        'type': 'json_schema',
        'schema': {
          'type': 'object',
          'properties': {
            'answer': {'type': 'string'},
          },
        },
      },
    },
  }, 'm');
  check(
    structured['response_format']['type'] == 'json_schema' &&
        structured['response_format']['json_schema']['schema']['properties']['answer']['type'] ==
            'string' &&
        !structured.containsKey('reasoning_effort'),
    'structured output schema or reasoning intent changed',
  );
  var rejected = false;
  try {
    messagesToChat({
      ...body,
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'document', 'source': {}},
          ],
        },
      ],
    }, 'm');
  } on ModelServiceFailure {
    rejected = true;
  }
  check(rejected, 'unrepresentable content silently dropped');

  final raw = {
    'id': 'chat-1',
    'choices': [
      {
        'message': {
          'content': 'Hello',
          'reasoning_content': 'Thought',
          'tool_calls': [
            {
              'id': 'call-2',
              'function': {'name': 'echo', 'arguments': '{"marker":"你好"}'},
            },
          ],
        },
        'finish_reason': 'tool_calls',
      },
    ],
    'usage': {
      'prompt_tokens': 100,
      'completion_tokens': 9,
      'prompt_tokens_details': {'cached_tokens': 20},
    },
  };
  final whole = messagesFromChat(raw, 'glm-5.3-flash');
  final cacheWrite = messagesFromChat({
    ...raw,
    'usage': {
      'prompt_tokens': 100,
      'completion_tokens': 9,
      'prompt_tokens_details': {'cached_tokens': 20, 'cache_write_tokens': 30},
    },
  }, 'm')['usage'];
  check(
    cacheWrite['input_tokens'] == 50 &&
        cacheWrite['cache_read_input_tokens'] == 20 &&
        cacheWrite['cache_creation_input_tokens'] == 30 &&
        cacheWrite['output_tokens'] == 9,
    'uncached input and cache-write token counts must retain their absolute values',
  );
  check(
    whole['model'] == 'glm-5.3-flash' && whole['stop_reason'] == 'tool_use',
    'response model or finish lost',
  );
  check(
    whole['usage']['input_tokens'] == 80 &&
        whole['usage']['cache_read_input_tokens'] == 20 &&
        whole['usage']['output_tokens'] == 9,
    'absolute token counts wrong',
  );
  check(
    (whole['content'] as List).last['input']['marker'] == '你好',
    'response tool arguments lost',
  );

  final events = [
    {
      'id': 'chat-2',
      'choices': [
        {
          'index': 0,
          'delta': {'reasoning_content': 'Thought'},
          'finish_reason': '',
        },
      ],
    },
    {
      'id': 'chat-2',
      'choices': [
        {
          'index': 0,
          'delta': {'content': '你'},
        },
      ],
    },
    {
      'id': 'chat-2',
      'choices': [
        {
          'index': 0,
          'delta': {'content': '好'},
        },
      ],
    },
    {
      'id': 'chat-2',
      'choices': [
        {
          'index': 0,
          'delta': {
            'tool_calls': [
              {
                'index': 0,
                'id': 'call-3',
                'function': {'name': 'ec', 'arguments': '{"marker":'},
              },
            ],
          },
        },
      ],
    },
    {
      'id': 'chat-2',
      'choices': [
        {
          'index': 0,
          'delta': {
            'tool_calls': [
              {
                'index': 0,
                'function': {'name': 'ho', 'arguments': '"你好"}'},
              },
            ],
          },
          'finish_reason': 'tool_calls',
        },
      ],
    },
    {'choices': [], 'usage': raw['usage']},
  ];
  final sse =
      ': heartbeat\r\n\r\n' +
      events.map((e) => 'data: ${jsonEncode(e)}\r\n\r\n').join() +
      'data: [DONE]\r\n\r\n';
  // Byte-sized chunks split UTF-8 characters and SSE boundaries deliberately.
  final reply = await messagesChatReply(
    ModelReply(
      200,
      'text/event-stream',
      Stream.fromIterable(utf8.encode(sse).map((b) => [b])),
    ),
    modelId: 'glm-5.3-flash',
    stream: true,
  );
  final parsed = await modelSseEvents(reply.body).toList();
  check(parsed.last.event == 'message_stop', 'stream terminal missing');
  final blocks = parsed
      .where((e) => e.event == 'content_block_start')
      .map((e) => jsonDecode(e.data))
      .toList();
  check(
    blocks.last['content_block']['name'] == 'echo' &&
        blocks.last['content_block']['id'] == 'call-3',
    'fragmented tool name or ID corrupted',
  );
  final toolDelta = parsed
      .where((e) => e.data.contains('input_json_delta'))
      .map((e) => jsonDecode(e.data))
      .single;
  check(
    jsonDecode(toolDelta['delta']['partial_json'])['marker'] == '你好',
    'fragmented tool JSON corrupted',
  );
  final usage = jsonDecode(
    parsed.singleWhere((e) => e.event == 'message_delta').data,
  )['usage'];
  check(
    usage['input_tokens'] == 80 &&
        usage['output_tokens'] == 9 &&
        usage['cache_read_input_tokens'] == 20,
    'stream token accounting changed',
  );
  rejected = false;
  try {
    final bad = await messagesChatReply(
      ModelReply(
        200,
        'text/event-stream',
        Stream.value(
          utf8.encode(
            'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n',
          ),
        ),
      ),
      modelId: 'glm-5.3-flash',
      stream: true,
    );
    await bad.body.drain<void>();
  } on ModelServiceFailure {
    rejected = true;
  }
  check(rejected, 'truncated upstream stream accepted as complete');
  print(
    'PASS Messages/Chat text, exact tokens, UTF-8 streaming, fragmented tools and truncation',
  );
}
