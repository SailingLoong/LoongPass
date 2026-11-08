import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../lib/zcode_model_provider.dart';
import '../lib/model_provider.dart';
import '../lib/model_http.dart';
import '../lib/zcode_api.dart';
import 'memory_account_store.dart';
import 'zcode_activities_checks.dart' as f;

void check(bool ok, String why) {
  if (!ok) throw StateError(why);
}

class Official extends f.FakeZcode {
  bool exhausted = false;
  @override
  Future<ZcodeReply> send(ZcodeRequest r, {bool Function()? isCurrent}) async {
    if (r.path == ZcodeApi.configPath)
      return ZcodeReply(
        200,
        f.envelope({
          'configs': {
            'builtin_provider_config_json':
                'https://config.zcode.test/provider.json',
          },
        }),
      );
    if (r.path == ZcodeApi.balancePath) {
      received.add(r);
      balanceCalls++;
      return ZcodeReply(
        200,
        f.envelope({
          'server_time': serverTime,
          'plans': [f.plan('gift')],
          'balances': [
            {
              'plan_id': 'night',
              'user_plan_id': 'gift',
              'remaining_units': exhausted ? 0 : 12345,
              'total_units': 20000,
              'used_units': exhausted ? 20000 : 7655,
              'expires_at': serverTime + 3600,
              'capabilities': ['model:glm-live'],
            },
          ],
        }),
      );
    }
    return super.send(r, isCurrent: isCurrent);
  }
}

class Wire implements ModelTransport {
  final calls = <(Uri, Map<String, String>, Object?)>[];
  bool quota = false;
  String? sseOverride;
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
    check(isCurrent(), 'lease invalid');
    calls.add((uri, headers, body));
    if (uri.host == 'config.zcode.test') {
      check(!headers.containsKey('Authorization'), 'JWT sent to public config');
      final config = {
        'config': {
          'providerConfigRules': {
            'providerRules': [
              {
                'providerId': 'account:zai-start-plan',
                'builtinModelIds': ['GLM-Live', 'GLM-Unowned'],
              },
            ],
          },
          'modelConfigRules': {
            'modelRules': [
              {
                'modelMatch': 'GLM-.*',
                'config': {
                  'properties': {'contextWindow': 131072},
                  'optionSpecs': {
                    'maxOutputTokens': {'max': 8192},
                  },
                },
              },
            ],
          },
        },
      };
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
      'paid fallback',
    );
    check(
      headers['Authorization'] == 'Bearer synthetic-bigmodel' &&
          headers['X-Device-Mid'] == f.context['deviceMid'],
      'identity/device mismatch',
    );
    final request = body as Map;
    check(
      (request['system'] as List).length == 3 &&
          request['system'][0]['text'] == 'You are ZCode, an interactive agent',
      'Start Plan native format absent',
    );
    final meta = jsonDecode(request['metadata']['user_id']);
    check(meta['device_id'] == f.context['deviceMid'], 'body device mismatch');
    final answer = quota
        ? jsonEncode({'code': '1005', 'msg': 'exceed quota limit'})
        : request['stream'] == true
        ? sseOverride ??
              'event: message_start\ndata: {"type":"message_start","message":{"id":"m","type":"message","role":"assistant","model":"GLM-Live","content":[]}}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n'
        : jsonEncode({
            'id': 'm',
            'type': 'message',
            'content': [
              {'type': 'text', 'text': '你好'},
            ],
            'usage': {'input_tokens': 7, 'output_tokens': 2},
          });
    await consume(
      ModelReply(
        200,
        quota || request['stream'] != true
            ? 'application/json'
            : 'text/event-stream',
        Stream.value(utf8.encode(answer)),
      ),
    );
  }
}

Future<void> main() async {
  final store = MemoryAccountStore('zcode-model');
  final http = Official();
  final owner = await f.account(store, http);
  final wire = Wire(),
      prompt =
          jsonDecode(
                await File(
                  'assets/protocols/zcode_start_prompt.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
  final source = ZcodeModelProvider(owner, prompt: prompt, transport: wire);
  try {
    final id = (await owner.accounts()).single.id;
    // Existing saved accounts predate registration IDs. The first lease may
    // publish registration and balance in separate durable writes.
    (store.data['accounts'][id] as Map).remove('registrationId');
    final catalog = await source.discoverModels(id);
    check(
      catalog.models.single.id == 'GLM-Live' &&
          catalog.models.single.contextWindow == 131072 &&
          catalog.models.single.outputLimit == 8192,
      'unowned model or guessed limit',
    );
    final summary = (await owner.accounts()).single.buckets.single;
    check(
      summary.remaining == 12345 && summary.unit == '单位未知',
      'balance absolute value changed',
    );
    final body = <String, dynamic>{
      'model': 'GLM-Live',
      'max_tokens': 1024,
      'system': 'Keep my original instructions',
      'messages': [
        {'role': 'user', 'content': '你好'},
      ],
      'tools': [
        {
          'name': 'echo',
          'input_schema': {'type': 'object'},
        },
      ],
    };
    await source.dispatch(
      id,
      catalog.registrationId,
      ModelProtocol.messages,
      body,
      (r) async {
        check(r.status == 200, 'native rejected');
        await r.body.drain<void>();
      },
      isCurrent: () => true,
      cancelled: Completer<void>().future,
    );
    final sent = wire.calls.last.$3 as Map;
    check(
      sent['system'][2]['text'].contains('Keep my original instructions') &&
          jsonEncode(sent['tools']) == jsonEncode(body['tools']),
      'original instructions/tools lost',
    );
    await source.dispatch(
      id,
      catalog.registrationId,
      ModelProtocol.messages,
      {...body, 'stream': true},
      (r) async {
        check(
          (await utf8.decoder.bind(r.body).join()).contains('message_stop'),
          'SSE lost',
        );
      },
      isCurrent: () => true,
      cancelled: Completer<void>().future,
    );
    const begin =
        'event: message_start\ndata: {"type":"message_start","message":{"id":"m"}}\n\n';
    const stop = 'event: message_stop\ndata: {"type":"message_stop"}\n\n';
    final framingFailures = <String>[];
    for (final sse in [
      ': heartbeat\n\n$begin$stop',
      '$begin$stop'.replaceAll('\n', '\r\n'),
    ]) {
      wire.sseOverride = sse;
      var complete = false;
      try {
        await source.dispatch(
          id,
          catalog.registrationId,
          ModelProtocol.messages,
          {...body, 'stream': true},
          (r) async {
            complete = (await utf8.decoder.bind(r.body).join()).contains(
              'message_stop',
            );
          },
          isCurrent: () => true,
          cancelled: Completer<void>().future,
        );
      } catch (_) {
        framingFailures.add(sse.contains('heartbeat') ? 'heartbeat' : 'CRLF');
      }
      if (!complete && framingFailures.isEmpty)
        framingFailures.add('missing terminal');
    }
    wire.sseOverride = begin;
    final beforeCut = wire.calls.length;
    var cut = false;
    try {
      await source.dispatch(
        id,
        catalog.registrationId,
        ModelProtocol.messages,
        {...body, 'stream': true},
        (r) async {
          await r.body.drain<void>();
        },
        isCurrent: () => true,
        cancelled: Completer<void>().future,
      );
    } catch (_) {
      cut = true;
    }
    if (!cut || wire.calls.length != beforeCut + 1)
      framingFailures.add('graceful truncation');
    check(framingFailures.isEmpty, 'SSE regressions: $framingFailures');
    wire.sseOverride = null;
    wire.quota = true;
    final count = wire.calls.length;
    await source.dispatch(
      id,
      catalog.registrationId,
      ModelProtocol.messages,
      body,
      (r) async {
        check(r.status == 429, 'HTTP200 quota hidden');
      },
      isCurrent: () => true,
      cancelled: Completer<void>().future,
    );
    check(wire.calls.length == count + 1, 'quota resent');
    http.exhausted = true;
    var refused = false;
    try {
      await source.dispatch(
        id,
        catalog.registrationId,
        ModelProtocol.messages,
        body,
        (_) async {},
        isCurrent: () => true,
        cancelled: Completer<void>().future,
      );
    } catch (_) {
      refused = true;
    }
    check(
      refused && wire.calls.length == count + 1,
      'known exhausted gift sent',
    );
    check(
      wire.calls
          .where(
            (c) => c.$1.host == 'open.bigmodel.cn' || c.$1.host == 'api.z.ai',
          )
          .isEmpty,
      'paid dispatch happened',
    );
    check(http.claims == 0, 'catalog or inference claimed gift');
    print(
      'PASS ZCode gift entitlement, exact balance, native format, tools/SSE, HTTP200 quota and zero paid fallback',
    );
  } finally {
    owner.dispose();
  }
}
