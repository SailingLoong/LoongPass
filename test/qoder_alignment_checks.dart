import 'dart:async';
import 'dart:convert';
import '../lib/model_http.dart';
import '../lib/model_provider.dart';
import '../lib/qoder_credits.dart';
import '../lib/qoder_device_accounts.dart';
import '../lib/qoder_model_provider.dart';
import '../lib/qoder_protocol.dart';
import '../lib/qoder_stream.dart';
import 'qoder_cn_checks.dart' show Native, Transport;
import 'qoder_model_provider_checks.dart' show decodeWire, frame;

void check(bool value, String why) {
  if (!value) throw StateError(why);
}

Map<String, dynamic> listingModel({bool always = false}) => {
  'key': 'qfmodel',
  'display_name': 'Qwen3.8-Flash',
  'enable': true,
  'source': 'system',
  'max_input_tokens': 180000,
  'max_output_tokens': 8192,
  'is_vl': true,
  'is_reasoning': true,
  'thinking_config': {
    'enabled': {
      'efforts': {
        'low': {},
        'medium': {},
        'high': {'is_default': true},
      },
    },
    if (!always) 'disabled': {},
  },
  'context_config': {
    '1m': {'token_count': 1000000},
    '200k': {'token_count': 200000, 'is_default': true},
    '400k': {'token_count': 400000},
  },
};

final tools = [
  {
    'type': 'function',
    'function': {
      'name': 'echo',
      'parameters': {
        'type': 'object',
        'properties': {
          'value': {'type': 'string'},
        },
      },
    },
  },
];
Map<String, dynamic> chat([Map<String, dynamic> extra = const {}]) => {
  'model': 'qfmodel',
  'messages': [
    {'role': 'system', 'content': 'Keep this instruction.'},
    {'role': 'user', 'content': 'hello'},
  ],
  ...extra,
};

class CatalogWire implements ModelTransport {
  final sent = <Map<String, dynamic>>[];
  final model = listingModel();
  String? answer;
  Completer<void>? replyWait;
  @override
  Future<void> exchange(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const {},
    Object? body,
    required bool Function() isCurrent,
    Future<void>? cancelled,
    required Future<void> Function(ModelReply) consume,
  }) async {
    check(isCurrent(), 'stale account admitted');
    if (method == 'POST') {
      sent.add(jsonDecode(decodeWire(body as String)));
      await replyWait?.future;
    }
    await consume(
      ModelReply(
        200,
        method == 'GET' ? 'application/json' : 'text/event-stream',
        Stream.value(
          utf8.encode(
            method == 'GET'
                ? jsonEncode({
                    'app': [model],
                  })
                : answer ??
                      frame({
                            'choices': [
                              {
                                'delta': {'content': 'ok'},
                                'finish_reason': 'stop',
                              },
                            ],
                          }) +
                          frame('[DONE]'),
          ),
        ),
      ),
    );
  }
}

class RefreshTransport extends Transport {
  int refreshes = 0;
  @override
  Future<QoderResponse> send(
    String method,
    Uri url,
    String? bearer,
    Map<String, dynamic>? body, {
    bool Function()? isCurrent,
  }) async {
    if (url.path.endsWith('/deviceToken/refresh')) {
      refreshes++;
      return QoderResponse(400, {'message': 'temporary request failure'});
    }
    return super.send(method, url, bearer, body, isCurrent: isCurrent);
  }
}

Future<(int, String)> readReply(
  String text, {
  int status = 200,
  Map<String, dynamic> extra = const {},
}) async {
  var output = '', code = 0;
  await consumeQoderReply(
    ModelReply(
      status,
      status == 200 ? 'text/event-stream' : 'application/json',
      Stream.value(utf8.encode(text)),
    ),
    chat({'tools': tools, 'stream': true, ...extra}),
    (r) async {
      code = r.status;
      output = await utf8.decoder.bind(r.body).join();
    },
  );
  return (code, output);
}

Future<void> main() async {
  var failures = 0;
  Future<void> test(String name, FutureOr<void> Function() run) async {
    try {
      await run();
      print('PASS $name');
    } catch (e) {
      failures++;
      print('FAIL $name: $e');
    }
  }

  await test('CN login uses the regional production client', () async {
    final owner = QoderDeviceAccounts(
      native: Native(),
      transport: Transport(),
      nowMs: () => 100000,
    );
    try {
      final login = await owner.startLogin();
      check(
        login.url.queryParameters['client_id'] ==
            'e883ade2-e6e3-4d6d-adf7-f92ceff5fdcb',
        'international client sent to CN sign-in',
      );
    } finally {
      owner.dispose();
    }
  });
  await test('refresh400 preserves a still-valid grant', () async {
    final native = Native(), transport = RefreshTransport();
    var now = 100000;
    final owner = QoderDeviceAccounts(
      native: native,
      transport: transport,
      nowMs: () => now,
    );
    try {
      await owner.startLogin();
      await owner.pollLogin();
      now = 3500000;
      var admitted = false;
      await owner.withInferenceAuthorization('account-a', (
        token,
        machine,
        registration,
        current,
      ) async {
        admitted = token == 'synthetic-access' && current();
      });
      final saved = jsonDecode(native.payload)['accounts']['account-a'];
      check(
        admitted &&
            transport.refreshes == 1 &&
            saved['authorizationInvalid'] != true,
        '400 disabled a usable authorization',
      );
    } finally {
      owner.dispose();
    }
  });
  await test(
    'catalog retains vision efforts and the largest context window',
    () async {
      final owner = QoderDeviceAccounts(
        native: Native(),
        transport: Transport(),
        nowMs: () => 100000,
      );
      try {
        await owner.startLogin();
        await owner.pollLogin();
        final provider = QoderModelProvider(owner, transport: CatalogWire());
        final m = (await provider.discoverModels('account-a')).models.single;
        check(
          m.contextWindow == 1000000 &&
              m.images == true &&
              m.reasoning == true &&
              m.defaultReasoningEffort == 'high' &&
              m.reasoningEfforts.join(',') == 'none,low,medium,high',
          'catalog facts discarded',
        );
      } finally {
        owner.dispose();
      }
    },
  );
  await test(
    'unrepresentable request constraints reject before any POST',
    () async {
      final owner = QoderDeviceAccounts(
        native: Native(),
        transport: Transport(),
        nowMs: () => 100000,
      );
      try {
        await owner.startLogin();
        await owner.pollLogin();
        final wire = CatalogWire();
        final provider = QoderModelProvider(owner, transport: wire);
        final registration = (await provider.discoverModels(
          'account-a',
        )).registrationId;
        final constraints = <Map<String, dynamic>>[
          {'n': 2},
          {'logprobs': true},
          {'top_logprobs': 5},
          {'seed': 42},
          {'temperature': 0},
          {'top_p': 0.9},
          {
            'stop': ['END'],
          },
          {'parallel_tool_calls': false},
          {
            'response_format': {
              'type': 'json_schema',
              'json_schema': {
                'name': 'answer',
                'schema': {'type': 'object'},
              },
            },
          },
          {
            'tool_choice': {
              'type': 'function',
              'function': {'name': 'echo'},
            },
          },
        ];
        for (final constraint in constraints) {
          final request = chat({'tools': tools, ...constraint});
          final expected = constraint.containsKey('tool_choice')
              ? 'unsupported_tool_choice'
              : 'unsupported_parameter';
          var preflight = false, dispatch = false;
          try {
            provider.validateRequest(ModelProtocol.chat, request);
          } on ModelServiceFailure catch (e) {
            preflight = e.code == expected;
          }
          try {
            await provider.dispatch(
              'account-a',
              registration,
              ModelProtocol.chat,
              request,
              (reply) => reply.body.drain<void>(),
              isCurrent: () => true,
              cancelled: Completer<void>().future,
            );
          } on ModelServiceFailure catch (e) {
            dispatch = e.code == expected;
          }
          check(
            preflight && dispatch && wire.sent.isEmpty,
            '${constraint.keys.single} was silently dropped or sent',
          );
        }
        final auto = qoderRequest(
          chat({'tools': tools, 'tool_choice': 'auto'}),
          listingModel(),
        );
        final none = qoderRequest(
          chat({'tools': tools, 'tool_choice': 'none'}),
          listingModel(),
        );
        final required = qoderRequest(
          chat({'tools': tools, 'tool_choice': 'required'}),
          listingModel(),
        );
        check(
          auto['tools'].length == 1 &&
              !none.containsKey('tools') &&
              required['system'][0]['text'].contains(
                'You must call an available function',
              ),
          'supported native tool choices changed',
        );
        provider.validateRequest(
          ModelProtocol.chat,
          chat({
            'metadata': {'user_id': '{"session_id":"fixture-session"}'},
            'user': 'end-user',
            'prompt_cache_key': 'fixture-cache',
            'stream': true,
            'stream_options': {'include_usage': true},
          }),
        );
      } finally {
        owner.dispose();
      }
    },
  );
  await test(
    'thinking uses catalog defaults and keeps mandatory thinking on',
    () {
      final standard = qoderRequest(chat(), listingModel())['parameters'];
      final small = qoderRequest(
        chat({'max_tokens': 64}),
        listingModel(),
      )['parameters'];
      final mandatory = qoderRequest(
        chat({'max_tokens': 64}),
        listingModel(always: true),
      )['parameters'];
      final onlyConfig = listingModel()..remove('is_reasoning');
      final configured = qoderRequest(
        chat({'reasoning_effort': 'max'}),
        onlyConfig,
      )['parameters'];
      check(
        standard['reasoning_effort'] == 'high' &&
            small['enable_thinking'] == false &&
            mandatory['enable_thinking'] == true &&
            mandatory['reasoning_effort'] == 'low' &&
            configured['reasoning_effort'] == 'high',
        'thinking_config or budget ignored',
      );
    },
  );
  await test(
    'mandatory thinking rejects explicit off before a model POST',
    () async {
      final owner = QoderDeviceAccounts(
        native: Native(),
        transport: Transport(),
        nowMs: () => 100000,
      );
      try {
        await owner.startLogin();
        await owner.pollLogin();
        final wire = CatalogWire();
        wire.model['thinking_config'] = listingModel(
          always: true,
        )['thinking_config'];
        final provider = QoderModelProvider(owner, transport: wire);
        final registration = (await provider.discoverModels(
          'account-a',
        )).registrationId;
        for (final off in ['none', 'off']) {
          var refused = false;
          try {
            await provider.dispatch(
              'account-a',
              registration,
              ModelProtocol.chat,
              chat({'reasoning_effort': off}),
              (reply) => reply.body.drain<void>(),
              isCurrent: () => true,
              cancelled: Completer<void>().future,
            );
          } on ModelServiceFailure catch (failure) {
            refused = failure.code == 'unsupported_reasoning_effort';
          }
          check(
            refused && wire.sent.isEmpty,
            '$off was coerced to thinking and sent',
          );
        }
        final implicit = qoderRequest(
          chat(),
          listingModel(always: true),
        )['parameters'];
        final optionalOff = qoderRequest(
          chat({'reasoning_effort': 'off'}),
          listingModel(),
        )['parameters'];
        check(
          implicit['enable_thinking'] == true &&
              implicit['reasoning_effort'] == 'high' &&
              optionalOff['enable_thinking'] == false,
          'implicit default or optional off changed',
        );
      } finally {
        owner.dispose();
      }
    },
  );
  await test(
    'context includes the reply and output never exceeds catalog ceiling',
    () {
      final input = chat({
        'max_tokens': 32000,
        'messages': [
          {'role': 'user', 'content': 'a' * 600000},
        ],
      });
      final p = qoderRequest(input, listingModel())['parameters'];
      check(
        p['context_length'] == 400000 && p['max_tokens'] == 8192,
        'wrong context window or output ceiling',
      );
    },
  );
  await test('native tools type object unions without changing the caller', () {
    final schema = {
      'oneOf': [
        {
          'type': 'object',
          'properties': {
            'a': {'type': 'string'},
          },
        },
        {
          'type': 'object',
          'properties': {
            'b': {'type': 'number'},
          },
        },
      ],
    };
    final original = jsonEncode(schema);
    final b = qoderRequest(
      chat({
        'tools': [
          {
            'type': 'function',
            'function': {'name': 'union', 'parameters': schema},
          },
        ],
      }),
      listingModel(),
    );
    check(
      b['tools'][0]['function']['parameters']['type'] == 'object' &&
          jsonEncode(schema) == original,
      'union not typed or input mutated',
    );
  });
  await test(
    'known nonreasoning rejects explicit on while unknown can forward it',
    () async {
      final owner = QoderDeviceAccounts(
        native: Native(),
        transport: Transport(),
        nowMs: () => 100000,
      );
      try {
        await owner.startLogin();
        await owner.pollLogin();
        final wire = CatalogWire();
        wire.model.remove('thinking_config');
        wire.model['is_reasoning'] = false;
        final provider = QoderModelProvider(owner, transport: wire);
        final catalog = await provider.discoverModels('account-a');
        var refused = false;
        try {
          await provider.dispatch(
            'account-a',
            catalog.registrationId,
            ModelProtocol.chat,
            chat({'reasoning_effort': 'high'}),
            (reply) => reply.body.drain<void>(),
            isCurrent: () => true,
            cancelled: Completer<void>().future,
          );
        } on ModelServiceFailure catch (failure) {
          refused = failure.code == 'unsupported_reasoning_effort';
        }
        check(
          catalog.models.single.reasoning == false &&
              refused &&
              wire.sent.isEmpty,
          'explicit on was dropped for a known nonreasoning model',
        );
        wire.model.remove('is_reasoning');
        wire.model.remove('reasoning_efforts');
        check(
          (await provider.discoverModels(
                'account-a',
              )).models.single.reasoning ==
              null,
          'unknown capability advertised as false',
        );
        final unknown = qoderRequest(
          chat({'reasoning_effort': 'high'}),
          wire.model,
        );
        check(
          unknown['parameters']['enable_thinking'] == true &&
              unknown['parameters']['reasoning_effort'] == 'high' &&
              unknown['model_config']['is_reasoning'] == true,
          'unknown source silently discarded explicit on',
        );
      } finally {
        owner.dispose();
      }
    },
  );
  await test(
    'Qoder prompt cache receives contents and the last-user marker',
    () {
      final body = qoderRequest(chat(), listingModel());
      final last = body['messages'].last;
      check(
        last['contents'] != null &&
            last['content'].last['cache_control']?['type'] == 'ephemeral',
        'native cache shape absent',
      );
    },
  );
  await test(
    'one explicit session keeps tool tasks but advances the next user prompt',
    () async {
      final owner = QoderDeviceAccounts(
        native: Native(),
        transport: Transport(),
        nowMs: () => 100000,
      );
      try {
        await owner.startLogin();
        await owner.pollLogin();
        final wire = CatalogWire(),
            provider = QoderModelProvider(owner, transport: wire);
        final registration = (await provider.discoverModels(
          'account-a',
        )).registrationId;
        final first = chat();
        final follow = chat({
          'messages': [
            ...first['messages'],
            {
              'role': 'assistant',
              'content': '',
              'tool_calls': [
                {
                  'id': 'c',
                  'type': 'function',
                  'function': {'name': 'echo', 'arguments': '{}'},
                },
              ],
            },
            {'role': 'tool', 'tool_call_id': 'c', 'content': 'ok'},
          ],
        });
        final next = chat({
          'messages': [
            ...follow['messages'],
            {'role': 'assistant', 'content': 'done'},
            {'role': 'user', 'content': 'next task'},
          ],
        });
        for (final b in [first, follow, next]) {
          final context = ModelRequestContext.fromRequest(
            b,
            session: 'session:worker',
          ).forAccount('qoder-cn/account-a/$registration');
          await provider.dispatch(
            'account-a',
            registration,
            ModelProtocol.chat,
            b,
            (r) => r.body.drain<void>(),
            isCurrent: () => true,
            cancelled: Completer<void>().future,
            context: context,
          );
        }
        final a = wire.sent[0], b = wire.sent[1], c = wire.sent[2];
        check(
          a['request_set_id'] == b['request_set_id'] &&
              c['request_set_id'] != a['request_set_id'] &&
              a['session_id'] == c['session_id'] &&
              b['business']['begin_at'] == a['business']['begin_at'] &&
              b['business']['stage'] == 'processing',
          'session and task lifecycles conflated',
        );
      } finally {
        owner.dispose();
      }
    },
  );
  await test('inline invocation examples stay text', () async {
    const prose =
        'Use `<function=echo><parameter=value>example</parameter></function>` as an example.';
    final r = await readReply(
      frame({
            'choices': [
              {
                'delta': {'content': prose},
                'finish_reason': 'stop',
              },
            ],
          }) +
          frame('[DONE]'),
    );
    final chunks = r.$2
        .split('\n')
        .where((l) => l.startsWith('data: {'))
        .map((l) => jsonDecode(l.substring(6)))
        .toList();
    final output = chunks
        .map((c) => c['choices'][0]['delta']['content'] ?? '')
        .join();
    check(
      !r.$2.contains('"tool_calls":[') && output == prose,
      'inline code became an executable tool call',
    );
  });
  await test(
    'Markdown code spans and fences never become tool calls across chunks',
    () async {
      const invocation =
          '<invoke name="echo"><parameter name="value">example</parameter></invoke>';
      final examples = [
        'Use ``$invocation`` as an example.',
        'Use ``a ` backtick $invocation`` as an example.',
        'Use ```a `` pair $invocation``` as an inline example.',
        '~~~xml\n$invocation\n~~~\n',
        '   ~~~~xml\n$invocation\n   ~~~~~\n',
        '````xml\n```\n$invocation\n````\n',
      ];
      for (final example in examples) {
        for (final parts in [
          [example],
          example.split(''),
        ]) {
          final response = await readReply(
            parts
                    .map(
                      (part) => frame({
                        'choices': [
                          {
                            'delta': {'content': part},
                          },
                        ],
                      }),
                    )
                    .join() +
                frame({
                  'choices': [
                    {'delta': {}, 'finish_reason': 'stop'},
                  ],
                }) +
                frame('[DONE]'),
          );
          final chunks = response.$2
              .split('\n')
              .where((line) => line.startsWith('data: {'))
              .map((line) => jsonDecode(line.substring(6)));
          final output = chunks
              .map((chunk) => chunk['choices'][0]['delta']['content'] ?? '')
              .join();
          check(
            !response.$2.contains('"tool_calls":[') && output == example,
            'Markdown example became executable or changed',
          );
        }
      }
      final outside = await readReply(
        '~~~xml\n$invocation\n~~~\n$invocation'
                .split('')
                .map(
                  (part) => frame({
                    'choices': [
                      {
                        'delta': {'content': part},
                      },
                    ],
                  }),
                )
                .join() +
            frame({
              'choices': [
                {'delta': {}, 'finish_reason': 'stop'},
              ],
            }) +
            frame('[DONE]'),
      );
      check(
        outside.$2.contains('"tool_calls":['),
        'real invocation after the closing fence was suppressed',
      );
      final inlineThenReal = await readReply(
        frame({
              'choices': [
                {
                  'delta': {'content': '```$invocation``` $invocation'},
                  'finish_reason': 'stop',
                },
              ],
            }) +
            frame('[DONE]'),
      );
      check(
        inlineThenReal.$2.contains('"tool_calls":['),
        'line-start inline span suppressed the real call after its matching run',
      );
    },
  );
  await test('function form inside tool_call is a declared tool', () async {
    final r = await readReply(
      frame({
            'choices': [
              {
                'delta': {
                  'content':
                      '<tool_call><function=echo><parameter=value>hello</parameter></function></tool_call>',
                },
                'finish_reason': 'stop',
              },
            ],
          }) +
          frame('[DONE]'),
    );
    check(
      r.$2.contains('"tool_calls":[') &&
          r.$2.contains('hello') &&
          !r.$2.contains('<tool_call>'),
      'wrapped XML tool form rejected',
    );
  });
  await test(
    'space and tab indented examples remain literal across chunks',
    () async {
      const invocation =
          '<invoke name="echo"><parameter name="value">example only</parameter></invoke>';
      final examples = [
        'Example:\n\n    $invocation\n',
        'Example:\n\n\t$invocation\n',
        'Example:\n\n   \t$invocation\n',
        '    ```xml\n    $invocation\n    ```\n',
        '\tUse `$invocation` as an example.\n',
      ];
      for (final example in examples) {
        for (final parts in [
          [example],
          example.split(''),
        ]) {
          final response = await readReply(
            parts
                    .map(
                      (part) => frame({
                        'choices': [
                          {
                            'delta': {'content': part},
                          },
                        ],
                      }),
                    )
                    .join() +
                frame({
                  'choices': [
                    {'delta': {}, 'finish_reason': 'stop'},
                  ],
                }) +
                frame('[DONE]'),
          );
          final chunks = response.$2
              .split('\n')
              .where((line) => line.startsWith('data: {'))
              .map((line) => jsonDecode(line.substring(6)));
          final output = chunks
              .map((chunk) => chunk['choices'][0]['delta']['content'] ?? '')
              .join();
          check(
            output == example && !response.$2.contains('"tool_calls":['),
            'indented example became a tool or lost text',
          );
        }
      }
      final text = '${examples[3]}\n$invocation';
      final outside = await readReply(
        text
                .split('')
                .map(
                  (part) => frame({
                    'choices': [
                      {
                        'delta': {'content': part},
                      },
                    ],
                  }),
                )
                .join() +
            frame({
              'choices': [
                {'delta': {}, 'finish_reason': 'stop'},
              ],
            }) +
            frame('[DONE]'),
      );
      final chunks = outside.$2
          .split('\n')
          .where((line) => line.startsWith('data: {'))
          .map((line) => jsonDecode(line.substring(6)))
          .toList();
      final output = chunks
          .map((chunk) => chunk['choices'][0]['delta']['content'] ?? '')
          .join();
      final calls = chunks
          .expand(
            (chunk) =>
                chunk['choices'][0]['delta']['tool_calls'] as List? ?? const [],
          )
          .toList();
      check(
        output == '${examples[3]}\n' &&
            calls.length == 1 &&
            calls.single['function']['name'] == 'echo',
        'unindented real call or literal indented delimiters were mishandled',
      );
    },
  );
  await test('HTTP queue and request codes retain vendor meaning', () async {
    final queued = await readReply(
      jsonEncode({
        'code': 10605,
        'message': jsonEncode({'isQueued': true, 'retryAfterSeconds': 17}),
      }),
      status: 403,
    );
    final refused = await readReply(
      jsonEncode({'code': 406, 'message': 'not multimodal'}),
      status: 403,
    );
    check(
      queued.$1 == 503 &&
          refused.$1 == 400 &&
          queued.$2.contains('upstream_queue'),
      'vendor failures became login errors',
    );
  });
  await test(
    'supported stream usage option controls returned usage metadata',
    () async {
      final text =
          frame({
            'choices': [
              {
                'delta': {'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
            'usage': {
              'prompt_tokens': 40,
              'completion_tokens': 106,
              'total_tokens': 146,
            },
          }) +
          frame('[DONE]');
      final hidden = await readReply(
        text,
        extra: {
          'stream_options': {'include_usage': false},
        },
      );
      final shown = await readReply(
        text,
        extra: {
          'stream_options': {'include_usage': true},
        },
      );
      check(
        !hidden.$2.contains('"usage":') &&
            shown.$2.contains('"total_tokens":146'),
        'allowed stream option was silently ignored',
      );
    },
  );
  await test('snake-case quota fields retain absolute remaining amounts', () {
    final result = normalizeQoderCredits({
      'displayMode': 'qoder',
      'qoderUsage': {
        'user_quota': {'total': 2000000, 'used': 1500000, 'unit': 'tokens'},
        'add_on_quota': {'cap': 1100, 'used': 245},
        'dedicated_resource_packages': [
          {'total': 10, 'used': 2},
        ],
      },
    }, DateTime.utc(2026, 11, 8));
    check(
      result.planRemaining == 500000 &&
          result.addOnRemaining == 855 &&
          result.packages.withoutExpiry == 8,
      'quota aliases or total-minus-used misread',
    );
  });
  await test('quota units remain attached to their amounts', () {
    final dynamic result = normalizeQoderCredits({
      'displayMode': 'qoder',
      'qoderUsage': {
        'userQuota': {'total': 2000000, 'remaining': 500000, 'unit': 'tokens'},
        'addOnQuota': {'cap': 1100, 'used': 245, 'unit': 'credits'},
      },
    }, DateTime.utc(2026, 11, 8));
    check(
      result.planUnit == 'tokens' &&
          result.addOnUnit == 'credits' &&
          result.planRemaining == 500000 &&
          result.addOnRemaining == 855,
      'token allowance mislabeled as credits',
    );
  });
  await test('expired packages cannot conflict with active quota units', () {
    final result = normalizeQoderCredits({
      'displayMode': 'qoder',
      'qoderUsage': {
        'dedicatedResourcePackages': [
          {'remaining': 8, 'unit': 'credits'},
          {'remaining': 500000, 'unit': 'tokens', 'expiresAt': 1},
        ],
      },
    }, DateTime.utc(2026, 11, 8));
    check(
      result.packages.withoutExpiry == 8 && result.packagesUnit == 'credits',
      'expired allowance changed active units',
    );
  });
  if (failures != 0) throw StateError('$failures Qoder alignment regressions');
}
