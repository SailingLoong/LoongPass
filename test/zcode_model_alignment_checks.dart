import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/model_http.dart';
import '../lib/model_provider.dart';
import '../lib/zcode_api.dart';
import '../lib/zcode_model_provider.dart';
import 'memory_account_store.dart';
import 'zcode_activities_checks.dart' as account;
import 'zcode_model_provider_checks.dart' as model;

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

class Official extends model.Official {
  bool ambiguous = false;
  @override
  Future<ZcodeReply> send(
    ZcodeRequest request, {
    bool Function()? isCurrent,
  }) async {
    if (ambiguous && request.path == ZcodeApi.balancePath) {
      return ZcodeReply(
        200,
        account.envelope({
          'server_time': serverTime,
          'plans': [account.plan('a'), account.plan('b')],
          'balances': [
            {
              'plan_id': 'night',
              'remaining_units': 12345,
              'capabilities': ['model:glm-live'],
            },
          ],
        }),
      );
    }
    return super.send(request, isCurrent: isCurrent);
  }
}

class Wire implements ModelTransport {
  final calls = <(Map<String, String>, Map<String, dynamic>)>[];
  bool stream = false;
  String? errorCode = 'synthetic-note';
  int? retryAfterSeconds = 37;
  Object answer = {
    'type': 'message',
    'content': [
      {'type': 'text', 'text': 'ToolSearchTool'},
      {
        'type': 'tool_use',
        'id': 'search-2',
        'name': 'ToolSearchTool',
        'input': {'query': 'select:Read'},
      },
    ],
  };
  final config = <String, dynamic>{
    'config': {
      'providerConfigRules': {
        'providerRules': [
          {
            'providerId': 'account:zai-start-plan',
            'builtinModelIds': ['GLM-Live'],
          },
        ],
      },
      'modelConfigRules': {
        'modelRules': [
          {
            'modelMatch': 'GLM-.*',
            'config': {
              'properties': {
                'contextWindow': 131072,
                'inputFormat': {'supportsImage': true},
              },
              'optionSpecs': {
                'maxOutputTokens': {'max': 8192},
                'reasoningLevel': {
                  'values': ['disabled', 'low', 'high', 'max'],
                },
              },
            },
          },
        ],
      },
    },
  };
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
    check(isCurrent(), 'invalid ZCode inference lease');
    if (method == 'GET') {
      await consume(
        ModelReply(
          200,
          'application/json',
          Stream.value(utf8.encode(jsonEncode(config))),
        ),
      );
      return;
    }
    check(
      uri.host == 'zcode.z.ai' &&
          uri.path == '/api/v1/zcode-plan/anthropic/v1/messages',
      'paid route used',
    );
    calls.add((headers, body as Map<String, dynamic>));
    final bytes = utf8.encode(
      stream
          ? 'event: message_start\ndata: {"type":"message_start","message":{"id":"m","type":"message","content":[]}}\n\n'
                'event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"search-2","name":"ToolSearchTool","input":{}}}\n\n'
                'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}\n\n'
                'event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n'
                'event: message_stop\ndata: {"type":"message_stop"}\n\n'
          : jsonEncode(answer),
    );
    await consume(
      ModelReply(
        200,
        stream ? 'text/event-stream' : 'application/json',
        Stream.fromIterable([
          bytes.sublist(0, 17),
          bytes.sublist(17, 89),
          bytes.sublist(89),
        ]),
        errorCode: errorCode,
        retryAfterSeconds: retryAfterSeconds,
      ),
    );
  }
}

Future<void> main() async {
  var failed = 0;
  Future<void> run(String name, Future<void> Function() test) async {
    try {
      await test();
      print('PASS $name');
    } catch (e) {
      failed++;
      print('FAIL $name: $e');
    }
  }

  final prompt =
      jsonDecode(
            await File(
              'assets/protocols/zcode_start_prompt.json',
            ).readAsString(),
          )
          as Map<String, dynamic>;
  Future<void> withSource(
    Future<void> Function(ZcodeModelProvider, Official, Wire, String, String)
    use,
  ) async {
    final http = Official();
    final owner = await account.account(
      MemoryAccountStore('zcode-model-alignment'),
      http,
    );
    try {
      final wire = Wire();
      final source = ZcodeModelProvider(owner, prompt: prompt, transport: wire);
      final id = (await owner.accounts()).single.id;
      final catalog = await source.discoverModels(id);
      await use(source, http, wire, id, catalog.registrationId);
      check(http.claims == 0, 'model operation claimed a gift');
    } finally {
      owner.dispose();
    }
  }

  Map<String, dynamic> request({bool collision = false}) => {
    'model': 'GLM-Live',
    'system': 'Preserve my system text',
    'messages': [
      {'role': 'user', 'content': 'hello'},
      {
        'role': 'assistant',
        'content': [
          {
            'type': 'tool_use',
            'id': 'search-1',
            'name': 'ToolSearch',
            'input': {'query': 'select:Read'},
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
              {'type': 'tool_reference', 'tool_name': 'Read'},
            ],
          },
        ],
      },
    ],
    'tool_choice': {'type': 'tool', 'name': 'ToolSearch'},
    'tools': [
      {
        'name': 'Bash',
        'input_schema': {'type': 'object'},
      },
      {
        'name': 'Read',
        'input_schema': {'type': 'object'},
        'defer_loading': true,
      },
      {
        'name': 'ToolSearch',
        'input_schema': {'type': 'object'},
      },
      if (collision)
        {
          'name': 'ToolSearchTool',
          'input_schema': {'type': 'object'},
        },
      {
        'name': 'DeferredToolPlaceholder',
        'input_schema': {'type': 'object'},
        'defer_loading': true,
      },
    ],
  };
  Future<void> send(
    ZcodeModelProvider source,
    String id,
    String registration,
    Map<String, dynamic> body,
    Future<void> Function(ModelReply) consume, {
    ModelRequestContext? context,
  }) => source.dispatch(
    id,
    registration,
    ModelProtocol.messages,
    body,
    consume,
    isCurrent: () => true,
    cancelled: Completer<void>().future,
    context: context,
  );

  await run(
    'ZCode context uses true UUID session, query and request attribution consistently',
    () => withSource((source, http, wire, id, registration) async {
      final body = request();
      final context = ModelRequestContext.fromRequest(
        body,
        session: 'session:worker',
        scope: 'zcode-account',
      );
      await send(
        source,
        id,
        registration,
        body,
        (r) async => r.body.drain<void>(),
        context: context,
      );
      final (headers, sent) = wire.calls.single;
      final metadata = jsonDecode(sent['metadata']['user_id']);
      check(
        headers['x-session-id'] == context.sessionId &&
            headers['x-query-id'] == context.turnId &&
            headers['x-request-id'] == context.requestId &&
            metadata['session_id'] == context.sessionId &&
            metadata['device_id'] == account.context['deviceMid'],
        'true session/turn/request attribution was lost',
      );
      await send(
        source,
        id,
        registration,
        body,
        (r) async => r.body.drain<void>(),
      );
      final first = wire.calls.last.$1['x-session-id'];
      await send(
        source,
        id,
        registration,
        body,
        (r) async => r.body.drain<void>(),
      );
      check(
        first != wire.calls.last.$1['x-session-id'],
        'identical text fabricated a conversation identity',
      );
    }),
  );

  await run(
    'ZCode retains tools and history while translating only endpoint ToolSearch controls',
    () => withSource((source, http, wire, id, registration) async {
      final body = request();
      final original = jsonEncode(body);
      await send(source, id, registration, body, (r) async {
        final value = jsonDecode(await utf8.decoder.bind(r.body).join());
        check(
          value['content'][1]['name'] == 'ToolSearch' &&
              value['content'][0]['text'] == 'ToolSearchTool',
          'JSON tool alias not restored precisely',
        );
        check(
          r.errorCode == 'synthetic-note' && r.retryAfterSeconds == 37,
          'reply metadata was lost',
        );
      });
      final sent = wire.calls.single.$2;
      check(
        jsonEncode((sent['tools'] as List).map((t) => t['name']).toList()) ==
            '["Bash","Read","ToolSearchTool"]',
        'real tools removed or placeholder retained',
      );
      check(
        (sent['tools'] as List).every((t) => !t.containsKey('defer_loading')),
        'deferred schema controls leaked',
      );
      check(
        sent['tool_choice']['name'] == 'ToolSearchTool',
        'forced search choice not translated',
      );
      final messages = sent['messages'] as List;
      check(
        messages[2]['content'][0]['name'] == 'ToolSearchTool' &&
            messages[3]['content'][0]['content'][0]['tool_name'] == 'Read',
        'tool history/reference changed incorrectly',
      );
      check(jsonEncode(body) == original, 'caller request was mutated');
    }),
  );

  await run(
    'ZCode restores streamed tool names across arbitrary chunk boundaries',
    () => withSource((source, http, wire, id, registration) async {
      wire.stream = true;
      await send(source, id, registration, request(), (r) async {
        final text = await utf8.decoder.bind(r.body).join();
        check(
          text.contains('"name":"ToolSearch"') &&
              !text.contains('"name":"ToolSearchTool"') &&
              text.contains('message_stop'),
          'SSE alias or completion lost',
        );
        check(
          r.errorCode == 'synthetic-note' && r.retryAfterSeconds == 37,
          'SSE reply metadata was lost',
        );
      });
    }),
  );

  await run(
    'an existing ZCode alias tool keeps its identity in both directions',
    () => withSource((source, http, wire, id, registration) async {
      await send(source, id, registration, request(collision: true), (r) async {
        final value = jsonDecode(await utf8.decoder.bind(r.body).join());
        check(
          value['content'][1]['name'] == 'ToolSearchTool',
          'real alias tool was renamed',
        );
      });
      check(
        (wire.calls.single.$2['tools'] as List)
                .where((t) => t['name'] == 'ToolSearch')
                .length ==
            1,
        'colliding tool identities were merged',
      );
    }),
  );

  await run(
    'ZCode catalog exposes configured image and reasoning facts',
    () => withSource((source, http, wire, id, registration) async {
      final definition = (await source.discoverModels(id)).models.single;
      check(
        definition.images == true &&
            definition.reasoning == true &&
            definition.alwaysThinks == false &&
            jsonEncode(definition.reasoningEfforts) ==
                '["none","low","high","max"]' &&
            definition.defaultReasoningEffort == null,
        'configured capability facts were lost or defaults invented',
      );
    }),
  );

  await run(
    'ZCode adapter obeys normalized owner entitlement ambiguity',
    () => withSource((source, http, wire, id, registration) async {
      http.ambiguous = true;
      var rejected = false;
      try {
        await send(
          source,
          id,
          registration,
          request(),
          (r) async => r.body.drain<void>(),
        );
      } on ModelServiceFailure catch (e) {
        rejected = e.code == 'gift_exhausted';
      }
      check(
        rejected && wire.calls.isEmpty,
        'ambiguous plan fallback sent inference',
      );
    }),
  );
  exitCode = failed == 0 ? 0 : 1;
}
