// Observable local HTTP behavior with synthetic account owners only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/model_service.dart';
import 'memory_account_store.dart';
import 'model_test_support.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  final store = MemoryAccountStore('pooling');
  final messages = PoolProvider('first', ModelProtocol.messages);
  final chat = PoolProvider('second', ModelProtocol.chat);
  final service = ModelService(store: store, port: 0)
    ..register(messages)
    ..register(chat);
  final client = HttpClient();
  try {
    await service.load();
    final a = await service.addAccount(providerId: 'first', accountId: 'a');
    final b = await service.addAccount(providerId: 'first', accountId: 'b');
    final c = await service.addAccount(providerId: 'second', accountId: 'a');
    check(service.bindings.length == 3, 'single account connection survived');
    check({a.key, b.key, c.key}.length == 3, 'account keys were shared');
    check(
      (await service.addAccount(providerId: 'first', accountId: 'a')).key ==
          a.key,
      'explicitly reselecting an account rotated its existing key',
    );
    await service.start();

    Future<(int, String)> request(
      String path,
      String key, {
      Object? body,
      String? origin,
      String? secondKey,
    }) async {
      final req = await client.openUrl(
        body == null ? 'GET' : 'POST',
        service.endpoint!.resolve(path),
      );
      req.headers.set('Authorization', 'Bearer $key');
      if (secondKey != null) req.headers.set('x-api-key', secondKey);
      if (origin != null) req.headers.set('Origin', origin);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final reply = await req.close();
      return (reply.statusCode, await utf8.decoder.bind(reply).join());
    }

    const firstModels = '/providers/first/messages/v1/models';
    const firstCall = '/providers/first/messages/v1/messages';
    const secondCall = '/providers/second/chat/v1/chat/completions';
    final beforeRead = messages.discoveries;
    for (final entry in [(a, 'only-a', 'only-b'), (b, 'only-b', 'only-a')]) {
      final reply = await request(firstModels, entry.$1.key);
      check(reply.$1 == 200, 'account catalog unavailable');
      final data = jsonDecode(reply.$2)['data'] as List;
      final ids = data.map((m) => m['id']).toList();
      check(
        ids.contains(entry.$2) && !ids.contains(entry.$3),
        'catalog leaked another account model',
      );
      check(
        (data.first as Map)['native_endpoints'] is List &&
            (data.first as Map)['native_endpoints'].single == '/messages',
        'catalog lacks native protocol metadata',
      );
    }
    check(
      messages.discoveries == beforeRead,
      'GET models triggered data refresh',
    );
    check(
      (await request(firstModels, 'wrong')).$1 == 401,
      'unknown key admitted',
    );
    check(
      (await request(firstModels, a.key, origin: 'https://example.test')).$1 ==
          403,
      'browser origin admitted',
    );
    check(
      (await request(firstModels, a.key, secondKey: b.key)).$1 == 401,
      'conflicting account keys admitted',
    );
    check(
      (await request(firstModels, c.key)).$1 == 403,
      'source boundary crossed',
    );
    final body = <String, dynamic>{
      'model': 'shared',
      'messages': [
        {'role': 'user', 'content': 'synthetic'},
      ],
      'max_tokens': 16,
      'stream': true,
      'tools': [
        {
          'name': 'echo',
          'input_schema': {'type': 'object'},
        },
      ],
    };
    final successful = await request(firstCall, a.key, body: body);
    check(
      successful.$1 == 200 && successful.$2.contains('message_stop'),
      'SSE lost',
    );
    check(
      messages.calls.length == 1 && messages.calls.single.$1 == 'a',
      'wrong account called',
    );
    check(
      jsonEncode(messages.calls.single.$3) == jsonEncode(body),
      'native tool/body payload changed',
    );
    check(
      (await request(secondCall, c.key, body: body)).$1 == 200,
      'second protocol unavailable',
    );
    check(
      chat.calls.length == 1 && chat.calls.single.$2 == ModelProtocol.chat,
      'wrong native protocol',
    );
    check(
      (await request(
            firstCall,
            a.key,
            body: {...body, 'model': 'only-b'},
          )).$1 ==
          404,
      'other account model admitted',
    );
    check(messages.calls.length == 1, 'rejected model reached upstream');
    check(
      (await request(firstCall, a.key, body: 'bad')).$1 == 400,
      'malformed body admitted',
    );
    check(
      (await request(
            firstCall,
            a.key,
            body: {
              ...body,
              'messages': ['x' * (2 * 1024 * 1024)],
            },
          )).$1 ==
          413,
      'oversized body admitted',
    );
    messages.status = 429;
    check(
      (await request(firstCall, b.key, body: body)).$1 == 429,
      'exhaustion hidden',
    );
    check(
      messages.calls.length == 2 && messages.calls.last.$1 == 'b',
      'exhaustion switched or replayed',
    );
    messages.status = 200;
    messages.transportFails = true;
    final unknown = await request(firstCall, a.key, body: body);
    check(
      unknown.$1 == 502 && !unknown.$2.contains('private'),
      'unknown outcome leaked private diagnostics',
    );
    check(messages.calls.length == 3, 'unknown outcome resent');
    messages.transportFails = false;
    check(
      service.importUriFor(a.id)!.queryParameters['id'] == 'loongpass-first',
      'source import identity unstable',
    );
    check(
      service
          .importUriFor(a.id)!
          .queryParameters['anthropic']!
          .endsWith('/providers/first/messages'),
      'wrong Messages base',
    );
    check(
      service
          .importUriFor(c.id)!
          .queryParameters['chat']!
          .endsWith('/providers/second/chat/v1'),
      'wrong Chat base',
    );

    // Normal token refresh keeps owner registration unchanged and key usable.
    messages.events.add(null);
    await service.settled;
    check(
      service.bindings.firstWhere((v) => v.id == a.id).key == a.key,
      'ordinary refresh invalidated key',
    );
    messages.registrations.remove('a');
    check(
      (await request(firstModels, a.key)).$1 == 503,
      'removed account catalog remained usable',
    );
    messages.registrations['a'] = 'new-registration-a';
    check(
      (await request(firstCall, a.key, body: body)).$1 == 503,
      'readded account revived previous grant',
    );
    check(messages.calls.length == 3, 'readded account reached old grant');
    final fresh = await service.addAccount(providerId: 'first', accountId: 'a');
    check(fresh.key != a.key, 'new account incarnation reused revoked key');
    check(
      (await request(firstModels, a.key)).$1 == 401,
      'old key survived explicit replacement',
    );
    await service.setEnabled(b.id, false);
    check(
      (await request(firstModels, b.key)).$1 == 401,
      'disabled account key admitted',
    );
    await service.revoke(c.id);
    check(
      (await request(secondCall, c.key, body: body)).$1 == 401,
      'revoked key admitted',
    );

    final savedKey = fresh.key;
    await service.dispose();
    final restored = ModelService(store: store, port: 0)
      ..register(messages)
      ..register(chat);
    try {
      await restored.load();
      check(
        restored.running && restored.bindings.any((v) => v.key == savedKey),
        'restart lost bindings or key',
      );
      check(
        restored.bindings.firstWhere((v) => v.id == b.id).enabled == false,
        'restart enabled an excluded account',
      );
      store.beforeWrite = () async =>
          throw StateError('synthetic disk failure');
      try {
        await restored.stop();
      } catch (_) {}
      check(
        restored.running && store.data['enabled'] == true,
        'failed stop save changed intent',
      );
      store.beforeWrite = null;
      store.afterWrite = () async =>
          throw StateError('synthetic lost acknowledgement');
      await restored.stop();
      store.afterWrite = null;
      check(
        !restored.running && store.data['enabled'] == false,
        'lost ack was not reconciled',
      );
    } finally {
      store.beforeWrite = null;
      store.afterWrite = null;
      await restored.dispose();
    }
    stdout.writeln(
      'PASS keyed multi-provider catalogs, routing, revocation, single send and restart',
    );
  } finally {
    client.close(force: true);
    await service.dispose();
    await messages.events.close();
    await chat.events.close();
  }
}
