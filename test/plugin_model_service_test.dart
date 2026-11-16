import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/plugin_runtime.dart';
import '../lib/plugin_accounts.dart';
import '../lib/plugin_model_service.dart';
import 'memory_account_store.dart';

// Inject the account owner's published authorization state while retaining the
// real native fixture, registration lifetime, and local HTTP admission path.
class _Accounts extends PluginAccounts {
  _Accounts({
    required super.runtime,
    required super.directory,
    required super.store,
    required super.enabledProviders,
  });
  String? authorizationError;
  Map<String, dynamic>? usageOverride;
  @override
  List<PluginAccount> get accounts => [
    for (final account in super.accounts)
      PluginAccount(
        key: account.key,
        facts: account.facts,
        active: account.active,
        models: account.models,
        usage: usageOverride ?? account.usage,
        queriedAt: account.queriedAt,
        error: authorizationError ?? account.error,
      ),
  ];
}

void main() {
  test('native account grants preserve context and errors and revoke by lifetime', () async {
    final dir = await Directory.systemTemp.createTemp(
      'loongpass-model-native-',
    );
    final runtime = await PluginRuntime.start(
      executable: Platform.environment['LOONGPASS_BUN'] ?? 'bun',
      hostPath: File('runtime/vendor/magpie/host.js').absolute.path,
      launcherPath: File('runtime/launcher.mjs').absolute.path,
      directory: dir.path,
      plugins: [
        {
          'spec': 'fixture',
          'target': File('test/fixtures/native_plugin.mjs').absolute.path,
          'options': {'apiId': 'fixture-wire', 'media': true},
        },
      ],
    );
    final accounts = _Accounts(
      runtime: runtime,
      directory: dir.path,
      store: MemoryAccountStore('accounts'),
      enabledProviders: {'fixture'},
    );
    final modelStore = MemoryAccountStore('models');
    final service = PluginModelService(
      accounts: accounts,
      store: modelStore,
      port: 0,
    );
    final client = HttpClient();
    try {
      for (final id in ['a', 'b']) {
        await runtime.call('import', {
          'provider': 'fixture',
          'key': 'fixture#$id',
          'auth': {
            'type': 'oauth',
            'uid': id,
            'accountId': id,
            'access': 'native-$id',
            'refresh': '',
            'expires': 0,
          },
        });
      }
      await accounts.start();
      await service.start();
      await service.enable('fixture#a', true);
      await service.enable('fixture#b', true);
      await service.setEnabled(true);
      final grant = service.grants.singleWhere(
        (g) => g.account.key == 'fixture#a',
      );
      Future<(int, Map<String, String>, String)> request(
        String path, {
        Map? body,
        String? token,
      }) async {
        final req = await client.openUrl(
          body == null ? 'GET' : 'POST',
          service.endpoint!.resolve(path),
        );
        req.headers.set('authorization', 'Bearer ${token ?? grant.token}');
        if (body != null) {
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(body));
        }
        final res = await req.close();
        final headers = <String, String>{};
        res.headers.forEach((k, v) => headers[k] = v.join(','));
        return (res.statusCode, headers, await utf8.decoder.bind(res).join());
      }

      final catalog = await request('/plugin/catalog');
      expect(catalog.$1, 200);
      expect(jsonDecode(catalog.$3)['account']['id'], 'fixture#a');
      expect(catalog.$3, isNot(contains('native-a')));
      expect(
        (jsonDecode(catalog.$3)['models'] as List).map((m) => m['id']),
        ['fixture-model', 'image'],
        reason: 'Video polling has no model context in native Magpie; retain images and chat only.',
      );
      accounts.usageOverride = {
        'windows': [
          {
            'models': ['IMAGE'],
            'balance': 12.25,
            'unit': 'credits',
          },
          {
            'notModels': ['ImAgE'],
            'balance': 9.5,
            'unit': 'credits',
          },
          {
            'models': ['unavailable-model'],
            'balance': 100,
            'unit': 'credits',
          },
        ],
      };
      final quotaCatalog = jsonDecode((await request('/plugin/catalog')).$3);
      expect(quotaCatalog['exportedUsage']['windows'], [
        {
          'models': ['accounts/fixture%23a/fixture/image'],
          'balance': 12.25,
          'unit': 'credits',
        },
        {
          'models': ['fixture/fixture-model'],
          'balance': 9.5,
          'unit': 'credits',
        },
      ]);
      expect(
        quotaCatalog['usage']['windows'],
        accounts.usageOverride!['windows'],
      );
      accounts.usageOverride = null;
      Map<String, dynamic> envelope(String path) => {
        'model': 'fixture-wire',
        'npm': '@ai-sdk/openai-compatible',
        'url': 'https://fixture.invalid/v1/$path',
        'method': 'POST',
        'headers': {
          'authorization': 'Bearer caller-secret',
          'x-api-key': 'local-secret',
        },
        'body': base64Encode(
          utf8.encode('{"model":"fixture-wire","messages":[]}'),
        ),
        'session': 'native-session',
      };
      final reply = await request(
        '/plugin/fetch',
        body: envelope('chat/completions'),
      );
      expect(reply.$1, 200);
      final echoed = jsonDecode(reply.$3);
      expect(echoed['access'], 'native-a');
      expect(echoed['authorization'], 'Bearer native-a');
      expect(echoed['session'], 'native-session');
      final scopedImage = {
        ...envelope('images/generations'),
        'model': 'accounts/fixture%23a/fixture/image',
        'body': base64Encode(
          utf8.encode('{"model":"image","prompt":"synthetic"}'),
        ),
      };
      expect((await request('/plugin/fetch', body: scopedImage)).$1, 200);
      expect(
        (await request(
          '/plugin/fetch',
          body: {...scopedImage, 'model': 'accounts/fixture%23b/fixture/image'},
        )).$1,
        400,
      );
      final bridgeDir = await Directory.systemTemp.createTemp(
        'loongpass-bridge-host-',
      );
      final bridge = await PluginRuntime.start(
        executable: Platform.environment['LOONGPASS_BUN'] ?? 'bun',
        hostPath: File('runtime/vendor/magpie/host.js').absolute.path,
        launcherPath: File('runtime/launcher.mjs').absolute.path,
        directory: bridgeDir.path,
        plugins: [
          {
            'spec': '@loongpass/magpie-bridge@0.1.0',
            'target': Directory('runtime/bridge').absolute.path,
          },
        ],
      );
      try {
        await bridge.call('apiKey', {
          'provider': 'loongpass',
          'method': 0,
          'account': 'new',
          'key': grant.token,
          'inputs': {
            'endpoint': service.endpoint.toString(),
            'email': 'fixture-a',
          },
        });
        final rows = await bridge.call('providers', {}) as List;
        expect((rows.single['models'] as List).map((m) => m['id']), [
          'fixture/fixture-model',
          'accounts/fixture%23a/fixture/image',
          'fixture',
          'auto',
        ]);
        final through = bridge.fetch({
          'provider': 'loongpass',
          'model': 'fixture-wire',
          'npm': '@ai-sdk/openai-compatible',
          'url': 'https://fixture.invalid/v1/chat/completions',
          'method': 'POST',
          'headers': {'x-magpie-work-dir': '/fixture/work'},
          'body': envelope('chat/completions')['body'],
          'session': 'bridge-session',
        });
        final response = await through.response;
        expect(response.status, 200);
        final payload = jsonDecode(
          await utf8.decoder.bind(response.body).join(),
        );
        expect(payload['authorization'], 'Bearer native-a');
        expect(payload['session'], 'bridge-session');
      } finally {
        await bridge.close();
        await bridgeDir.delete(recursive: true);
      }
      // Reading either side of the many-to-many view uses the same grants.
      await service.setModelAccountEnabled('fixture', 'fixture#a', false);
      expect(
        (await request('/plugin/fetch', body: envelope('chat/completions'))).$1,
        429,
      );
      expect(
        service.catalog.singleWhere((m) => m.id == 'fixture').availableAccounts,
        1,
      );
      await service.setModelAccountEnabled('fixture', 'fixture#a', true);
      accounts.authorizationError = 'authorization_required';
      expect(
        (await request('/plugin/fetch', body: envelope('chat/completions'))).$1,
        429,
      );
      expect(service.catalog.first.availableAccounts, 0);
      accounts.authorizationError = 'usage_unavailable';
      expect(
        (await request('/plugin/fetch', body: envelope('chat/completions'))).$1,
        200,
      );
      accounts.authorizationError = null;
      final refusedWindow = {
        'models': ['fixture-model'],
        'amount': 2000000,
        'limit': 2000000,
        'used': 100,
        'unit': 'tokens',
        'refused': true,
      };
      accounts.usageOverride = {
        'windows': [
          {
            ...refusedWindow,
            'resetsAt': DateTime.now()
                .add(const Duration(minutes: 1))
                .toIso8601String(),
          },
        ],
      };
      expect(
        (await request('/plugin/fetch', body: envelope('chat/completions'))).$1,
        429,
      );
      accounts.usageOverride = {
        'windows': [
          {
            ...refusedWindow,
            'resetsAt': DateTime.now()
                .subtract(const Duration(seconds: 1))
                .toIso8601String(),
          },
        ],
      };
      expect(
        (await request('/plugin/fetch', body: envelope('chat/completions'))).$1,
        200,
      );
      accounts.usageOverride = null;
      await service.reorderModels(['image', 'fixture']);
      expect(service.catalog.first.id, 'image');
      expect(modelStore.data['routing']['order'], ['image', 'fixture']);
      await service.setModelEnabled('fixture', false);
      expect(
        (jsonDecode((await request('/plugin/catalog')).$3)['models'] as List)
            .map((m) => m['id']),
        ['image'],
      );
      await service.setModelEnabled('fixture', true);
      final refused = await request('/plugin/fetch', body: envelope('refused'));
      expect(refused.$1, 429);
      expect(refused.$2['retry-after'], '7');
      expect(jsonDecode(refused.$3)['error']['code'], 11128);
      expect(
        (await request(
          '/plugin/fetch',
          body: {...envelope('videos'), 'model': 'video-wire'},
        )).$1,
        400,
        reason: 'An unsupported video job must not be created through a model grant.',
      );
      expect(
        (await request(
          '/plugin/fetch',
          body: {...envelope('x'), 'url': 'https://other.invalid/steal'},
        )).$1,
        400,
      );
      expect(
        (await request(
          '/plugin/fetch',
          body: {...envelope('chat/completions'), 'npm': '@ai-sdk/anthropic'},
        )).$1,
        400,
        reason: 'An API id cannot select an undeclared SDK',
      );
      expect((await request('/plugin/catalog', token: 'invalid')).$1, 401);
      await accounts.authorizationSaved('fixture#a');
      expect((await request('/plugin/catalog')).$1, 401);
      final other = service.grants.singleWhere(
        (g) => g.account.key == 'fixture#b',
      );
      expect((await request('/plugin/catalog', token: other.token)).$1, 200);
      modelStore.afterWrite = () async =>
          throw StateError('lost acknowledgment');
      await expectLater(service.enable('fixture#b', false), throwsStateError);
      expect(
        (await request('/plugin/catalog', token: other.token)).$1,
        401,
        reason:
            'A durable revocation remains effective after lost acknowledgment',
      );
      modelStore.afterWrite = null;
      await service.enable('fixture#b', true);
      await runtime.call('import', {
        'provider': 'fixture',
        'key': 'fixture#b',
        'auth': {
          'type': 'oauth',
          'uid': 'different-owner',
          'accountId': 'different-owner',
          'access': 'other-owner-secret',
          'refresh': '',
          'expires': 0,
        },
      });
      expect(
        (await request(
          '/plugin/fetch',
          token: other.token,
          body: envelope('chat/completions'),
        )).$1,
        401,
        reason: 'Native identity is checked at admission, before background refresh',
      );
    } finally {
      client.close(force: true);
      await service.close();
      await accounts.close();
      await runtime.close();
      await dir.delete(recursive: true);
    }
  });
}
