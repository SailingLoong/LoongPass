import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../lib/model_service.dart';
import 'memory_account_store.dart';

void check(bool ok, String why) {
  if (!ok) throw StateError(why);
}

class Source extends ModelProvider {
  Source(this.id, this.protocol);
  @override
  final String id;
  final ModelProtocol protocol;
  final registrations = {'account': 'registration'};
  final calls = <Map<String, dynamic>>[];
  int status = 200, discoveries = 0;
  bool rejectMedia = false, extraModel = false;
  @override
  void validateRequest(ModelProtocol protocol, Map<String, dynamic> body) {
    if (rejectMedia && jsonEncode(body).contains('image_url')) {
      throw const ModelServiceFailure('unsupported_content');
    }
  }

  @override
  String get name => id;
  @override
  Set<ModelProtocol> get protocols => {protocol};
  @override
  Future<List<ModelAccount>> accounts() async => [
    for (final e in registrations.entries)
      ModelAccount(e.key, e.key, registrationId: e.value),
  ];
  @override
  Future<ModelCatalog> discoverModels(String accountId) async {
    discoveries++;
    return ModelCatalog(
      registrationId: registrations[accountId]!,
      models: [
        ModelDefinition(
          id == 'one' ? 'GLM-5.3-Flash' : 'glm-5.3-flash',
          canonicalId: 'GLM-5.3-Flash',
          protocol: protocol,
          tools: true,
        ),
        if (extraModel)
          const ModelDefinition(
            'qwen3.8-flash',
            canonicalId: 'qwen3.8-flash',
            protocol: ModelProtocol.chat,
          ),
      ],
    );
  }

  @override
  Future<void> dispatch(
    String accountId,
    String registrationId,
    ModelProtocol protocol,
    Map<String, dynamic> body,
    Future<void> Function(ModelReply) consume, {
    required bool Function() isCurrent,
    required Future<void> cancelled,
  }) async {
    check(isCurrent(), 'stale route');
    calls.add(body);
    final response = protocol == ModelProtocol.chat
        ? {
            'id': 'chat',
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'OK'},
                'finish_reason': 'stop',
              },
            ],
            'usage': {'prompt_tokens': 3, 'completion_tokens': 1},
          }
        : {
            'id': 'msg',
            'type': 'message',
            'role': 'assistant',
            'model': body['model'],
            'content': [
              {'type': 'text', 'text': 'OK'},
            ],
            'stop_reason': 'end_turn',
            'usage': {'input_tokens': 3, 'output_tokens': 1},
          };
    await consume(
      ModelReply(
        status,
        'application/json',
        Stream.value(utf8.encode(jsonEncode(response))),
      ),
    );
  }
}

class Ineligible extends Source {
  Ineligible() : super('ineligible', ModelProtocol.messages);
  @override
  Future<ModelCatalog> discoverModels(String accountId) async =>
      throw const ModelServiceFailure('gift_unavailable');
}

Future<void> main() async {
  final store = MemoryAccountStore('unified'),
      one = Source('one', ModelProtocol.chat),
      two = Source('two', ModelProtocol.messages);
  var service = ModelService(store: store, port: 0)
    ..register(one)
    ..register(two)
    ..register(Ineligible());
  final client = HttpClient();
  try {
    await service.load();
    store.beforeWrite = () async => throw StateError('synthetic disk failure');
    var saveFailed = false;
    try {
      await service.connectSavedAccounts();
    } on ModelServiceFailure catch (e) {
      saveFailed = e.code == 'save_failed';
    }
    check(saveFailed, 'bulk enrollment hid a persistent storage failure');
    store.beforeWrite = null;
    final all = await service.connectSavedAccounts();
    check(
      all.connected == 2 &&
          all.unavailable == 1 &&
          service.bindings.length == 2,
      'bulk connection did not isolate an ineligible account',
    );
    final a = await service.addAccount(providerId: 'one', accountId: 'account');
    final b = await service.addAccount(providerId: 'two', accountId: 'account');
    await service.start();
    final command = service.pooledMagpieCommand!;
    final update = service.pooledMagpieUpdateCommand!;
    check(
      command.contains("'add' 'LoongPass' 'id=loongpass'") &&
          update.contains("'set' 'loongpass'") &&
          !update.contains('id=loongpass'),
      'native update can create a second provider',
    );
    check(
      command.contains(
        r'header.X-LoongPass-Session=${sessionId}:${subagentId}',
      ),
      'Magpie session propagation missing',
    );
    check(
      command.contains('errors=pass') && command.contains('patience=off'),
      'Magpie can replay failed requests',
    );
    final poolKey = service.pooledKey!;
    Future<(int, Map<String, dynamic>)> call(
      String path,
      String key, {
      String? session,
      Map<String, dynamic>? body,
    }) async {
      final req = await client.openUrl(
        body == null ? 'GET' : 'POST',
        service.endpoint!.resolve(path),
      );
      req.headers.set('x-api-key', key);
      if (session != null) req.headers.set('x-loongpass-session', session);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close();
      return (
        res.statusCode,
        jsonDecode(await utf8.decoder.bind(res).join()) as Map<String, dynamic>,
      );
    }

    final before = one.discoveries + two.discoveries;
    final catalog = await call('/v1/models', poolKey);
    check(
      catalog.$1 == 200 && (catalog.$2['data'] as List).length == 1,
      'unified catalog not deduplicated',
    );
    check(
      catalog.$2['data'][0]['account_count'] == 2 &&
          (catalog.$2['data'][0]['platforms'] as List).length == 2,
      'source counts wrong',
    );
    check(
      one.discoveries + two.discoveries == before,
      'catalog read drove discovery',
    );
    check(
      (await call('/v1/models', a.key)).$1 == 404,
      'old account key expanded to pool',
    );
    final body = <String, dynamic>{
      'model': 'glm-5.3-flash',
      'messages': [
        {'role': 'user', 'content': 'Hello'},
      ],
      'max_tokens': 16,
    };
    one.rejectMedia = true;
    final imageReply = await call(
      '/v1/messages',
      poolKey,
      session: 'image-session',
      body: {
        ...body,
        'messages': [
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'image-call',
                'name': 'screenshot',
                'input': {},
              },
            ],
          },
          {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'image-call',
                'content': [
                  {
                    'type': 'image',
                    'source': {
                      'type': 'base64',
                      'media_type': 'image/png',
                      'data': 'synthetic',
                    },
                  },
                ],
              },
            ],
          },
        ],
      },
    );
    check(
      imageReply.$1 == 200 && one.calls.isEmpty && two.calls.length == 1,
      'request was routed to an adapter that would lose its image',
    );
    one.rejectMedia = false;
    two.calls.clear();
    check(
      (await call('/v1/messages', poolKey, session: 's1', body: body)).$1 ==
          200,
      'first pooled request failed',
    );
    final selected = one.calls.isNotEmpty ? one : two;
    final other = identical(selected, one) ? two : one;
    for (var i = 0; i < 3; i++)
      await call('/v1/messages', poolKey, session: 's1', body: body);
    check(
      selected.calls.length == 4 && other.calls.isEmpty,
      'session moved between sources',
    );
    check(
      (await call('/v1/messages', poolKey, session: 's2', body: body)).$1 ==
              200 &&
          other.calls.length == 1,
      'independent session not distributed',
    );
    selected.status = 429;
    final failed = await call(
      '/v1/messages',
      poolKey,
      session: 's1',
      body: body,
    );
    check(
      failed.$1 == 429 && other.calls.length == 1,
      'failed request silently replayed',
    );
    check(
      (await call('/v1/messages', poolKey, session: 's1', body: body)).$1 ==
              200 &&
          other.calls.length == 2,
      'next request did not leave failed account',
    );
    final oldCalls = one.calls.length;
    await service.setEnabled(a.id, false);
    await call('/v1/messages', poolKey, session: 's3', body: body);
    check(one.calls.length == oldCalls, 'disabled account still routed');
    await service.revoke(b.id);
    check(
      (await call('/v1/messages', poolKey, session: 's3', body: body)).$1 ==
          404,
      'revoked model still dispatched',
    );
    await service.dispose();
    service = ModelService(store: store, port: 0)
      ..register(one)
      ..register(two);
    await service.load();
    check(service.pooledKey == poolKey, 'pooled key changed on restart');
    await service.setEnabled(a.id, true);
    one.extraModel = true;
    await service.refreshModels(a.id);
    check(
      service.pooledMagpieUpdateCommand!.contains('qwen3.8-flash'),
      'native update omitted the changed model catalog',
    );
    await service.rotatePooledKey();
    check(service.pooledKey != poolKey, 'pooled key cannot be revoked');
    check(
      service.pooledMagpieUpdateCommand!.contains(service.pooledKey!) &&
          !service.pooledMagpieUpdateCommand!.contains(poolKey),
      'native update still contains the revoked grant',
    );
    check(
      (await call('/v1/models', poolKey)).$1 == 401,
      'rotated pooled grant still accepted',
    );
    print(
      'PASS unified model grants, catalogs, sticky cross-platform routing, no replay and restart',
    );
  } finally {
    client.close(force: true);
    await service.dispose();
  }
}
