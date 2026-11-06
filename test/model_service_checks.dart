// Synthetic transport and isolated store. Executed by Claude Code for this task.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/model_service.dart';
import 'memory_account_store.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

class SyntheticProvider implements ModelProvider {
  @override
  String get id => 'synthetic';
  @override
  String get name => 'Synthetic';
  int calls = 0;
  int status = 200;
  bool fail = false;
  Map<String, dynamic>? received;
  @override
  Future<List<ModelAccount>> accounts() async => [
    const ModelAccount('account-a', 'Synthetic account'),
  ];
  @override
  Future<void> dispatch(
    String accountId,
    Map<String, dynamic> body,
    Future<void> Function(ModelReply) consume,
  ) async {
    check(accountId == 'account-a', 'account selection changed');
    calls++;
    received = body;
    if (fail) throw StateError('synthetic private diagnostic');
    await consume(
      ModelReply(
        status,
        'text/event-stream',
        Stream.fromIterable([
          utf8.encode(
            'event: message_start\ndata: {"type":"message_start"}\n\n',
          ),
          utf8.encode('event: message_stop\ndata: {"type":"message_stop"}\n\n'),
        ]),
      ),
    );
  }
}

Future<void> main() async {
  final store = MemoryAccountStore('model-service-synthetic');
  final provider = SyntheticProvider();
  final service = ModelService(store: store, port: 0);
  service.register(provider);
  final client = HttpClient();
  try {
    await service.load();
    check(!service.running, 'first launch must wait for explicit setup');
    await service.configure(
      providerId: provider.id,
      accountId: 'account-a',
      model: 'synthetic-model',
    );
    await service.start();
    final endpoint = service.endpoint!;
    final key = service.callerKey!;
    check(endpoint.host == '127.0.0.1', 'listener escaped loopback');
    check(key.length >= 32, 'caller key lacks entropy');
    check(
      !store.data.toString().contains('accessToken'),
      'copied platform token',
    );

    Future<(int, String)> request(
      String path, {
      String? authorization,
      String? origin,
      Object? body,
    }) async {
      final req = await client.openUrl(
        body == null ? 'GET' : 'POST',
        endpoint.resolve(path),
      );
      if (authorization != null)
        req.headers.set('Authorization', authorization);
      if (origin != null) req.headers.set('Origin', origin);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final response = await req.close();
      return (response.statusCode, await utf8.decoder.bind(response).join());
    }

    check(
      (await request('/v1/models')).$1 == 401,
      'anonymous catalog admitted',
    );
    check(
      (await request('/v1/models', authorization: 'Bearer wrong')).$1 == 401,
      'incorrect caller admitted',
    );
    check(
      (await request(
            '/v1/models',
            authorization: 'Bearer $key',
            origin: 'https://example.test',
          )).$1 ==
          403,
      'browser origin admitted',
    );
    final catalog = await request('/v1/models', authorization: 'Bearer $key');
    check(catalog.$1 == 200, 'catalog unavailable');
    final models = jsonDecode(catalog.$2) as Map<String, dynamic>;
    check(
      models['data'][0]['id'] == 'synthetic-model',
      'configured model changed',
    );
    final import = service.importUri!;
    check(
      import.scheme == 'magpie' && import.host == 'import',
      'invalid official import link',
    );
    check(import.queryParameters['key'] == key, 'wrong import caller key');
    check(
      import.queryParameters['anthropic'] == endpoint.toString(),
      'wrong import endpoint',
    );

    final body = {
      'model': 'synthetic-model',
      'messages': [
        {'role': 'user', 'content': 'synthetic'},
      ],
      'max_tokens': 8,
      'stream': true,
      'tools': [
        {
          'name': 'synthetic_tool',
          'input_schema': {'type': 'object'},
        },
      ],
    };
    final result = await request(
      '/v1/messages',
      authorization: 'Bearer $key',
      body: body,
    );
    check(
      result.$1 == 200 && result.$2.contains('message_stop'),
      'SSE was truncated',
    );
    check(provider.calls == 1, 'request was dispatched more than once');
    check(
      jsonEncode(provider.received) == jsonEncode(body),
      'message/tool payload changed',
    );
    final malformed = await request(
      '/v1/messages',
      authorization: 'Bearer $key',
      body: 'not an object',
    );
    check(
      malformed.$1 == 400 && provider.calls == 1,
      'invalid request reached upstream',
    );
    final oversized = await request(
      '/v1/messages',
      authorization: 'Bearer $key',
      body: {
        ...body,
        'messages': [
          {'role': 'user', 'content': 'x' * (2 * 1024 * 1024)},
        ],
      },
    );
    check(
      oversized.$1 == 413 && provider.calls == 1,
      'unbounded request admitted',
    );
    final unknown = await request(
      '/v1/messages',
      authorization: 'Bearer $key',
      body: {...body, 'model': 'unknown'},
    );
    check(
      unknown.$1 == 404 && provider.calls == 1,
      'unknown model reached upstream',
    );

    provider.status = 429;
    final rejected = await request(
      '/v1/messages',
      authorization: 'Bearer $key',
      body: body,
    );
    check(
      rejected.$1 == 429 && provider.calls == 2,
      'quota rejection was replayed',
    );
    provider.fail = true;
    final uncertain = await request(
      '/v1/messages',
      authorization: 'Bearer $key',
      body: body,
    );
    check(
      uncertain.$1 == 502 && provider.calls == 3,
      'uncertain result was replayed',
    );
    check(!uncertain.$2.contains('private diagnostic'), 'private error leaked');

    await service.dispose();
    final restored = ModelService(store: store, port: 0)..register(provider);
    try {
      await restored.load();
      check(
        restored.running && restored.callerKey == key,
        'enabled connection/key did not survive restart',
      );
      store.beforeWrite = () async => throw StateError('disk unavailable');
      try {
        await restored.stop();
      } catch (_) {}
      check(
        restored.running && store.data['enabled'] == true,
        'failed stop save changed runtime without persisting intent',
      );
      store.beforeWrite = null;
      store.afterWrite = () async => throw StateError('lost acknowledgement');
      await restored.stop();
      store.afterWrite = null;
      check(
        !restored.running && store.data['enabled'] == false,
        'stop did not persist',
      );
    } finally {
      store.beforeWrite = null;
      store.afterWrite = null;
      await restored.dispose();
    }

    final failingStore = MemoryAccountStore('model-service-save-failure');
    final failing = ModelService(store: failingStore, port: 0)
      ..register(provider);
    try {
      await failing.load();
      await failing.configure(
        providerId: provider.id,
        accountId: 'account-a',
        model: 'synthetic-model',
      );
      failingStore.beforeWrite = () async =>
          throw StateError('disk unavailable');
      try {
        await failing.start();
      } catch (_) {}
      check(
        !failing.running && failing.endpoint == null,
        'failed persistence left listener running',
      );
    } finally {
      await failing.dispose();
    }
    final occupied = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bindFailure = ModelService(store: store, port: occupied.port)
      ..register(provider);
    try {
      try {
        await bindFailure.load();
      } catch (_) {}
      // The saved connection was stopped above, so load must not bind.
      try {
        await bindFailure.start();
      } catch (_) {}
      check(
        !bindFailure.running && bindFailure.error == 'port_unavailable',
        'port conflict reported a running service',
      );
    } finally {
      await bindFailure.dispose();
      await occupied.close(force: true);
    }
    stdout.writeln(
      'PASS model service authentication, SSE, routing, persistence and failure boundaries',
    );
  } finally {
    client.close(force: true);
    await service.dispose();
  }
}
