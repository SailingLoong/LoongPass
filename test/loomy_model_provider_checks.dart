import 'dart:async';
import 'dart:convert';
import '../lib/loomy_model_provider.dart';
import '../lib/model_http.dart';
import '../lib/model_provider.dart';
import '../lib/rewards/reward_accounts.dart';
import '../lib/rewards/loomy_provider.dart';
import 'memory_account_store.dart';
import 'reward_test_support.dart' show NoNetwork;

void check(bool ok, String why) {
  if (!ok) throw StateError(why);
}

class Wire implements ModelTransport {
  final calls = <(Uri, Map<String, String>, Object?)>[];
  var status = 200;
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
    final token = headers['token'];
    check(headers['Authorization'] == 'Bearer $token', 'missing dual auth');
    final data = method == 'GET'
        ? jsonEncode({
            'code': '000000',
            'data': [
              {
                'id': 'only-$token',
                'name': 'Official',
                'context_window': 65536,
                'max_tokens': 4096,
                'capabilities': {'function_calling': true},
              },
              {
                'id': 'image-only',
                'name': 'Image generation',
                'capabilities': {
                  'input_modalities': ['text', 'image'],
                  'output_modalities': ['image'],
                  'function_calling': false,
                },
              },
            ],
          })
        : 'data: {"choices":[{"delta":{"content":"你好"}}]}\n\ndata: [DONE]\n\n';
    await consume(
      ModelReply(
        status,
        method == 'GET' ? 'application/json' : 'text/event-stream',
        Stream.value(utf8.encode(data)),
      ),
    );
  }
}

Future<void> main() async {
  final store = MemoryAccountStore('loomy-model')
    ..data = {
      'version': 1,
      'accounts': {
        for (final uid in ['one', 'two'])
          jsonEncode(['loomy', uid]): {
            'provider': 'loomy',
            'identity': uid,
            'label': 'Saved $uid',
            'automatic': false,
            'credentials': {'userid': uid, 'access_token': uid},
          },
      },
      'journals': {},
    };
  final owner = RewardAccounts(
    store: store,
    providers: [LoomyProvider()],
    transportFor: (_) => NoNetwork(),
  );
  await owner.restore();
  final wire = Wire();
  final source = LoomyModelProvider(owner, transport: wire);
  try {
    final first = await source.discoverModels('one'),
        second = await source.discoverModels('two');
    check(
      first.models.single.id == 'only-one' &&
          second.models.single.id == 'only-two',
      'catalog crossed accounts',
    );
    check(
      first.models.single.contextWindow == 65536 &&
          first.models.single.outputLimit == 4096 &&
          first.models.single.tools == true,
      'catalog exact facts',
    );
    check(
      wire.calls.first.$1.toString() ==
          'https://loomyad.xunfei.cn/api/v1/models',
      'wrong catalog route',
    );
    final body = <String, dynamic>{
      'model': 'only-one',
      'messages': [
        {
          'role': 'assistant',
          'tool_calls': [
            {
              'id': 'call-1',
              'type': 'function',
              'function': {'name': 'echo', 'arguments': '{}'},
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'call-1', 'content': '你好'},
      ],
      'stream': true,
    };
    String text = '';
    await source.dispatch(
      'one',
      first.registrationId,
      ModelProtocol.chat,
      body,
      (r) async {
        text = await utf8.decoder.bind(r.body).join();
      },
      isCurrent: () => true,
      cancelled: Completer<void>().future,
    );
    check(text.contains('你好') && text.contains('[DONE]'), 'SSE changed');
    check(identical(wire.calls.last.$3, body), 'tools or Chinese rewritten');
    check(
      wire.calls.last.$2['Content-Type'] == 'application/json;charset=utf-8',
      'UTF-8 missing',
    );
    final before = wire.calls.length;
    wire.status = 401;
    await source.dispatch(
      'one',
      first.registrationId,
      ModelProtocol.chat,
      body,
      (r) async {
        check(r.status == 401, 'login failure hidden');
      },
      isCurrent: () => true,
      cancelled: Completer<void>().future,
    );
    check(wire.calls.length == before + 1, 'session rejection retried');
    wire.status = 200;
    await owner.remove('loomy', 'one');
    var rejected = false;
    try {
      await source.dispatch(
        'one',
        first.registrationId,
        ModelProtocol.chat,
        body,
        (_) async {},
        isCurrent: () => true,
        cancelled: Completer<void>().future,
      );
    } catch (_) {
      rejected = true;
    }
    check(rejected && wire.calls.length == before + 1, 'removed account sent');
    check(
      (store.data['journals'] as Map).isEmpty,
      'model discovery claimed gift',
    );
    print(
      'PASS Loomy keyed live catalog, dual headers, UTF-8, tool results, SSE and removed session',
    );
  } finally {
    owner.dispose();
  }
}
