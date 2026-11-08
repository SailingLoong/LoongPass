import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../lib/qoder_device_accounts.dart';
import '../lib/qoder_model_provider.dart';
import '../lib/model_provider.dart';
import '../lib/model_http.dart';
import 'qoder_cn_checks.dart' show Native, Transport;

void check(bool ok, String why) {
  if (!ok) throw StateError(why);
}

String decodeWire(String wire) {
  const alphabet =
      '_doRTgHZBKcGVjlvpC,@aFSx#DPuNJme&i*MzLOEn)sUrthbf%Y^w.(kIQyXqWA!';
  const standard =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final n = wire.length ~/ 3;
  final s = n == 0
      ? wire
      : wire.substring(wire.length - n) +
            wire.substring(n, wire.length - n) +
            wire.substring(0, n);
  return utf8.decode(
    base64Decode(
      s
          .split('')
          .map((c) => c == '\$' ? '=' : standard[alphabet.indexOf(c)])
          .join(),
    ),
  );
}

String frame(Object value, {int status = 200}) =>
    'data: ${jsonEncode({'statusCodeValue': status, 'body': value is String ? value : jsonEncode(value)})}\n\n';

class Wire implements ModelTransport {
  final calls = <(Uri, Map<String, String>, Object?)>[];
  String displayName = 'Live';
  String answer =
      frame({
        'choices': [
          {
            'delta': {'content': '你好'},
            'finish_reason': 'stop',
          },
        ],
      }) +
      frame({
        'choices': [],
        'usage': {
          'prompt_tokens': 40,
          'completion_tokens': 106,
          'total_tokens': 146,
        },
      }) +
      frame('[DONE]');
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
    check(isCurrent(), 'stale lease');
    calls.add((uri, headers, body));
    check(uri.host == 'gateway.qoder.com.cn', 'wrong inference region');
    final auth = headers['Authorization']!.substring(12).split('.');
    final payload = auth[0], sig = auth[1];
    final path = uri.path.substring(5);
    check(
      sig ==
          md5
              .convert(
                utf8.encode(
                  '$payload\n${headers['Cosy-Key']}\n${headers['Cosy-Date']}\n${body ?? ''}\n$path',
                ),
              )
              .toString(),
      'incorrect signed path/body',
    );
    check(base64Decode(headers['Cosy-Key']!).length == 128, 'RSA wrap missing');
    final envelope = jsonDecode(utf8.decode(base64Decode(payload)));
    check(
      envelope['version'] == 'v1' &&
          envelope['info'] is String &&
          !jsonEncode(envelope).contains('synthetic'),
      'plaintext auth envelope',
    );
    if (method == 'GET') {
      await consume(
        ModelReply(
          200,
          'application/json',
          Stream.value(
            utf8.encode(
              jsonEncode({
                'app': [
                  {
                    'key': 'live-model',
                    'source': 'system',
                    'display_name': displayName,
                    'enable': true,
                    'max_input_tokens': 131072,
                    'max_output_tokens': 8192,
                    'format': 'openai',
                  },
                  {'key': 'disabled', 'enable': false},
                  {'key': 'auto', 'enable': true},
                ],
              }),
            ),
          ),
        ),
      );
    } else {
      final decoded = jsonDecode(decodeWire(body as String));
      check(
        decoded['business']['model_key'] == 'live-model' &&
            decoded['model_config']['key'] == 'live-model',
        'wrong billing model',
      );
      check(
        !decoded['model_config'].containsKey('enable'),
        'sent full listing as model config',
      );
      await consume(
        ModelReply(
          200,
          'text/event-stream',
          Stream.fromIterable(utf8.encode(answer).map((b) => [b])),
        ),
      );
    }
  }
}

Future<void> main() async {
  final native = Native(), http = Transport();
  final owner = QoderDeviceAccounts(
    native: native,
    transport: http,
    nowMs: () => 100000,
  );
  await owner.startLogin();
  await owner.pollLogin();
  final wire = Wire(), source = QoderModelProvider(owner, transport: wire);
  try {
    final catalog = await source.discoverModels('account-a');
    check(
      catalog.models.single.id == 'live-model' &&
          catalog.models.single.contextWindow == 131072,
      'entitlement or absolute limit wrong',
    );
    wire.displayName = 'Kimi-K3.1-Pro';
    final named = await source.discoverModels('account-a');
    check(
      named.models.single.canonicalId == 'Kimi-K3.1-Pro' &&
          named.models.single.id == 'live-model',
      'official model identity not separated from opaque platform key',
    );
    wire.displayName = 'Fast';
    check(
      (await source.discoverModels('account-a')).models.single.canonicalId ==
          null,
      'generic lane claimed an underlying model',
    );
    final body = <String, dynamic>{
      'model': 'live-model',
      'messages': [
        {'role': 'system', 'content': '原样保留'},
        {'role': 'user', 'content': '你好'},
      ],
      'stream': true,
      'max_tokens': 1024,
    };
    var text = '';
    await source.dispatch(
      'account-a',
      catalog.registrationId,
      ModelProtocol.chat,
      body,
      (r) async {
        text = await utf8.decoder.bind(r.body).join();
      },
      isCurrent: () => true,
      cancelled: Completer<void>().future,
    );
    check(
      text.contains('你好') &&
          text.contains('"prompt_tokens":40') &&
          text.contains('"completion_tokens":106') &&
          text.contains('[DONE]'),
      'stream or trailing absolute usage lost',
    );
    final request = jsonDecode(decodeWire(wire.calls.last.$3 as String));
    check(request['system'][0]['text'] == '原样保留', 'system rewritten');
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
    wire.answer =
        frame({
          'choices': [
            {
              'delta': {
                'content':
                    '<function_calls><invoke name="echo"><parameter name="value">你好</parameter></invoke></function_calls>',
              },
              'finish_reason': 'stop',
            },
          ],
        }) +
        frame('[DONE]');
    await source.dispatch(
      'account-a',
      catalog.registrationId,
      ModelProtocol.chat,
      {...body, 'tools': tools},
      (r) async {
        text = await utf8.decoder.bind(r.body).join();
      },
      isCurrent: () => true,
      cancelled: Completer<void>().future,
    );
    check(
      text.contains('tool_calls') &&
          text.contains('echo') &&
          !text.contains('<invoke'),
      'XML tool not lifted',
    );
    final follow = {
      ...body,
      'messages': [
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'c1',
              'type': 'function',
              'function': {'name': 'echo', 'arguments': '{}'},
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'c1', 'content': '结果'},
      ],
    };
    await source.dispatch(
      'account-a',
      catalog.registrationId,
      ModelProtocol.chat,
      follow,
      (r) async {
        await r.body.drain<void>();
      },
      isCurrent: () => true,
      cancelled: Completer<void>().future,
    );
    final msg =
        jsonDecode(decodeWire(wire.calls.last.$3 as String))['messages']
            as List;
    check(
      msg.last['tool_call_id'] == 'c1' && msg.last['content'] == '结果',
      'tool result pairing lost',
    );
    final beforeBad = wire.calls.length;
    var invalid = false;
    try {
      await source.dispatch(
        'account-a',
        catalog.registrationId,
        ModelProtocol.chat,
        {
          ...body,
          'messages': [
            {'role': 'tool', 'tool_call_id': 'orphan', 'content': 'result'},
          ],
        },
        (_) async {},
        isCurrent: () => true,
        cancelled: Completer<void>().future,
      );
    } catch (_) {
      invalid = true;
    }
    check(
      invalid && wire.calls.length == beforeBad,
      'orphan tool result dispatched',
    );
    wire.answer = frame({
      'choices': [
        {
          'delta': {'content': 'partial'},
        },
      ],
    });
    var cut = false;
    try {
      await source.dispatch(
        'account-a',
        catalog.registrationId,
        ModelProtocol.chat,
        body,
        (r) async {
          await r.body.drain<void>();
        },
        isCurrent: () => true,
        cancelled: Completer<void>().future,
      );
    } catch (_) {
      cut = true;
    }
    check(
      cut && wire.calls.length == beforeBad + 1,
      'cut stream completed or resent',
    );
    final count = wire.calls.length;
    wire.answer = frame({'code': '10605', 'message': 'queued'}, status: 503);
    await source.dispatch(
      'account-a',
      catalog.registrationId,
      ModelProtocol.chat,
      body,
      (r) async {
        check(r.status == 503, 'queue failure hidden');
      },
      isCurrent: () => true,
      cancelled: Completer<void>().future,
    );
    check(wire.calls.length == count + 1, 'queue resent');
    var rejected = false;
    try {
      QoderModelProvider(
        QoderDeviceAccounts(
          region: QoderRegion.global,
          native: Native(),
          transport: Transport(),
          nowMs: () => 100000,
        ),
      );
    } catch (_) {
      rejected = true;
    }
    check(rejected, 'CN source accepted global owner');
    print(
      'PASS Qoder COSY signature, encoded billing model, SSE usage, XML tools, pairing and single-send queue',
    );
  } finally {
    owner.dispose();
  }
}
