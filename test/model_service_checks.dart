import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../lib/model_service.dart';
import 'memory_account_store.dart';
import 'model_test_support.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> fails(Future<void> Function() action, String code) async {
  try {
    await action();
  } on ModelServiceFailure catch (e) {
    check(e.code == code, 'expected $code, got ${e.code}');
    return;
  }
  throw StateError('expected $code');
}

Future<void> main() async {
  final missingProvider = PoolProvider('first', ModelProtocol.messages);
  final missing = ModelService(
    store: MemoryAccountStore('removed-legacy-model')
      ..data = {
        'version': 1,
        'enabled': false,
        'providerId': 'first',
        'accountId': 'a',
        'model': 'removed-model',
        'key': List.filled(43, 'z').join(),
      },
    port: 0,
  )..register(missingProvider);
  try {
    await missing.load();
    await missing.start();
    check(
      missing.importUriFor('legacy') == null,
      'removed legacy model produced a broken import link',
    );
  } finally {
    await missing.dispose();
    await missingProvider.events.close();
  }
  final store = MemoryAccountStore('migration')
    ..data = {
      'version': 1,
      'enabled': true,
      'providerId': 'first',
      'accountId': 'a',
      'model': 'only-a',
      'key': List.filled(43, 'x').join(),
    };
  final provider = PoolProvider('first', ModelProtocol.messages);
  final service = ModelService(store: store, port: 0)..register(provider);
  final client = HttpClient();
  Future<(int, String)> request(
    String path, {
    Map<String, Object?>? body,
  }) async {
    final r = await client.openUrl(
      body == null ? 'GET' : 'POST',
      service.endpoint!.resolve(path),
    );
    r.headers.set('x-api-key', store.data['bindings']['legacy']['key']);
    if (body != null) r.write(jsonEncode(body));
    final response = await r.close();
    return (response.statusCode, await utf8.decoder.bind(response).join());
  }

  try {
    await service.load();
    check(service.running, 'saved intent restores without opening a page');
    check(
      service.bindings.single.key == List.filled(43, 'x').join(),
      'legacy key changed',
    );
    check(
      service.importUriFor('legacy')!.queryParameters['models'] == 'only-a',
      'legacy import advertised extra models',
    );
    check(
      service.bindings.single.models.length == 1,
      'legacy UI advertised extra models',
    );
    final models = await request('/v1/models');
    check(models.$1 == 200, 'legacy root unavailable');
    final data = (jsonDecode(models.$2) as Map)['data'] as List;
    check(
      data.length == 1 && data.single['id'] == 'only-a',
      'migration broadened model grant',
    );
    check(
      (await request(
            '/v1/messages',
            body: {'model': 'shared', 'messages': []},
          )).$1 ==
          404,
      'old key gained a new model',
    );
    check(
      (await request(
            '/v1/messages',
            body: {'model': 'only-a', 'messages': []},
          )).$1 ==
          200,
      'old model stopped working',
    );
    final before = provider.discoveries;
    await request('/v1/models');
    check(provider.discoveries == before, 'read triggered discovery');
    // Revoke while a response is held: lease cancellation must unblock it.
    provider.hold = Completer<void>();
    final pending = request(
      '/v1/messages',
      body: {'model': 'only-a', 'messages': []},
    );
    while (provider.calls.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await service.revoke('legacy');
    try {
      await pending.timeout(const Duration(seconds: 2));
    } catch (_) {}
    check(provider.disconnected > 0, 'revocation did not cancel upstream');
    await service.stop();
  } finally {
    await service.dispose();
    client.close(force: true);
    await provider.events.close();
  }

  final blocker = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final p = PoolProvider('first', ModelProtocol.messages);
  final s = ModelService(
    store: MemoryAccountStore('atomic-start'),
    port: blocker.port,
  )..register(p);
  await s.load();
  await s.addAccount(providerId: p.id, accountId: 'a');
  await fails(s.start, 'port_unavailable');
  check(!s.running, 'port collision pretended to start');
  await blocker.close(force: true);
  await s.dispose();
  await p.events.close();
  final bad = ModelService(
    store: MemoryAccountStore('bad')
      ..data = {
        'version': 2,
        'enabled': true,
        'bindings': {'bad': {}},
      },
    port: 0,
  );
  await fails(bad.load, 'invalid_settings');
  check(!bad.running, 'invalid settings started');
  await bad.dispose();
  print(
    'PASS v1 least-privilege migration, startup, cancellation and port conflicts',
  );
}
