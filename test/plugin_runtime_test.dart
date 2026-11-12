import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/plugin_runtime.dart';

void main() {
  late Directory directory;
  PluginRuntime? runtime;

  Future<PluginRuntime> open({String? refreshURL}) => PluginRuntime.start(
    executable: Platform.environment['LOONGPASS_BUN'] ?? 'bun',
    hostPath: File('runtime/vendor/magpie/host.js').absolute.path,
    launcherPath: File('runtime/launcher.mjs').absolute.path,
    directory: directory.path,
    plugins: [
      {
        'spec': 'fixture',
        'target': File('test/fixtures/native_plugin.mjs').absolute.path,
        'options': {'refreshURL': refreshURL},
      },
    ],
  );

  Future<void> importAccount(String id) => runtime!.call('import', {
    'provider': 'fixture',
    'key': 'fixture#$id',
    'auth': {
      'type': 'oauth',
      'access': 'fake-$id',
      'refresh': '',
      'expires': 0,
      'accountId': 'same display name',
      'uid': id,
    },
  });

  Map<String, Object?> request(String path, {String account = 'a'}) => {
    'provider': 'fixture',
    'account': 'fixture#$account',
    'model': 'fixture-model',
    'npm': '@ai-sdk/openai-compatible',
    'url': 'https://fixture.invalid/$path',
    'method': 'POST',
    'headers': <String, String>{},
    'session': 'same-session',
    'body': base64Encode(
      utf8.encode(
        '{"model":"fixture-model","messages":[{"role":"user","content":"hi"}]}',
      ),
    ),
  };

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('loongpass-plugin-test-');
  });
  tearDown(() async {
    await runtime?.close();
    runtime = null;
    await directory.delete(recursive: true);
  });

  test(
    'cancelled native authorization never publishes a late credential',
    () async {
      runtime = await open();
      final started = await runtime!.call('authorize', {
        'provider': 'fixture',
        'method': 0,
      }) as Map;
      final cancel = Completer<void>();
      final result = runtime!.call('callback', {
        'session': started['session'],
      }, cancellation: cancel.future);
      final rejected = expectLater(
        result,
        throwsA(isA<PluginRuntimeFailure>()),
      );
      cancel.complete();
      await rejected;
      await runtime!.close();
      final file = File('${directory.path}/plugin-auth.json');
      expect(
        await file.exists() ? jsonDecode(await file.readAsString()) : {},
        isEmpty,
      );
    },
  );

  test(
    'failed plugin initialization cannot expose a partially loaded host',
    () async {
      PluginRuntime? broken;
      try {
        await expectLater(
          () async => broken = await PluginRuntime.start(
            executable: Platform.environment['LOONGPASS_BUN'] ?? 'bun',
            hostPath: File('runtime/vendor/magpie/host.js').absolute.path,
            launcherPath: File('runtime/launcher.mjs').absolute.path,
            directory: directory.path,
            plugins: [
              {'spec': 'missing', 'target': '${directory.path}/missing.mjs'},
            ],
          ),
          throwsA(isA<PluginRuntimeFailure>()),
        );
      } finally {
        await broken?.close();
      }
    },
  );

  test('one host owns a credential directory until it exits', () async {
    runtime = await open();
    PluginRuntime? second;
    try {
      await expectLater(
        () async => second = await open(),
        throwsA(isA<PluginRuntimeFailure>()),
      );
    } finally {
      await second?.close();
    }
    await runtime!.close();
    runtime = await open();
    await importAccount('a');
    expect(await runtime!.call('providers', {}), isNotEmpty);
  });

  test(
    'native account imports survive restart without merging same-name users',
    () async {
      runtime = await open();
      for (final id in ['a', 'b']) {
        await importAccount(id);
      }
      await runtime!.close();
      runtime = await open();
      final rows = await runtime!.call('providers', {}) as List;
      final accounts = (rows.single as Map)['accounts'] as List;
      expect(accounts.map((a) => a['key']), ['fixture#a', 'fixture#b']);
      final saved = jsonDecode(
        await File('${directory.path}/plugin-auth.json').readAsString(),
      ) as Map;
      expect(saved['fixture#a']['access'], 'fake-a');
      expect(saved['fixture#b']['access'], 'fake-b');
    },
  );

  test('native fetch uses each account and chat headers while another stream waits', () async {
    runtime = await open();
    await importAccount('a');
    await importAccount('b');
    final waiting = runtime!.fetch(request('hang'));
    await waiting.response;
    final answer = await runtime!.fetch(request('echo', account: 'b')).response;
    final body = jsonDecode(await utf8.decoder.bind(answer.body).join()) as Map;
    expect(body['access'], 'fake-b');
    expect(body['authorization'], 'Bearer fake-b');
    expect(body['session'], 'same-session');
    expect(body['body']['messages'], [
      {'role': 'user', 'content': 'hi'},
    ]);
    await waiting.cancel();
    final stats = await runtime!.fetch(request('stats')).response;
    expect(
      jsonDecode(await utf8.decoder.bind(stats.body).join())['aborted'],
      1,
    );
  });

  test(
    'slow consumer drains beyond the native credit window without truncation',
    () async {
      runtime = await open();
      await importAccount('a');
      final answer = await runtime!.fetch(request('large')).response;
      var bytes = 0;
      await for (final chunk in answer.body) {
        expect(chunk.every((b) => b == 97), isTrue);
        bytes += chunk.length;
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(bytes, 2621440);
    },
  );

  test(
    'supplier rejection keeps status detail and semantic response headers',
    () async {
      runtime = await open();
      await importAccount('a');
      final answer = await runtime!.fetch(request('refused')).response;
      expect(answer.status, 429);
      expect(answer.headers['retry-after'], '7');
      expect(answer.headers['x-magpie-sign-in'], 'kept');
      expect(
        await utf8.decoder.bind(answer.body).join(),
        '{"error":{"code":11128,"message":"vendor detail"}}',
      );
    },
  );

  test(
    'host exit fails pending fetch instead of reporting an empty success',
    () async {
      runtime = await open();
      await importAccount('a');
      final request = runtime!.fetch({
        'provider': 'fixture',
        'account': 'fixture#a',
        'npm': '@ai-sdk/openai-compatible',
        'model': 'fixture-model',
        'url': 'https://fixture.invalid/exit',
      });
      await expectLater(request.response, throwsA(isA<PluginRuntimeFailure>()));
    },
  );

  test('cancellation before response head completes locally and host remains usable', () async {
    runtime = await open();
    await importAccount('a');
    final waiting = runtime!.fetch(request('hang'));
    final cancelled = expectLater(
      waiting.response,
      throwsA(isA<PluginRuntimeFailure>()),
    );
    await waiting.cancel();
    await cancelled;
    final answer = await runtime!.fetch(request('echo')).response;
    expect(
      jsonDecode(await utf8.decoder.bind(answer.body).join())['access'],
      'fake-a',
    );
  });

  test(
    'shutdown drains a rotating grant and saves it before the host exits',
    () async {
      runtime = await open();
      await runtime!.call('import', {
        'provider': 'fixture',
        'key': 'fixture#a',
        'auth': {
          'type': 'oauth',
          'access': 'fake-old',
          'refresh': 'fake-once',
          'expires': 1,
          'accountId': 'a',
          'uid': 'a',
        },
      });
      final renewal = runtime!.call('keepSignedIn', {
        'provider': 'fixture',
        'account': 'fixture#a',
      });
      await runtime!.close();
      expect((await renewal as Map)['renewed'], isTrue);
      final saved = jsonDecode(
        await File('${directory.path}/plugin-auth.json').readAsString(),
      );
      expect(saved['fixture#a']['access'], 'fake-renewed');
      expect(saved['fixture#a']['refresh'], 'fake-next');
    },
  );

  test(
    'bounded shutdown leaves the credential lease with an unfinished renewal',
    () async {
      final vendor = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => vendor.close(force: true));
      runtime = await open(refreshURL: 'http://127.0.0.1:${vendor.port}/refresh');
      await runtime!.call('import', {
        'provider': 'fixture',
        'key': 'fixture#a',
        'auth': {
          'type': 'oauth',
          'access': 'fake-old',
          'refresh': 'fake-once',
          'expires': 1,
          'accountId': 'a',
          'uid': 'a',
        },
      });
      final renewal = runtime!.call('keepSignedIn', {
        'provider': 'fixture',
        'account': 'fixture#a',
      });
      // Hold the vendor response until the second host has checked the lease.
      // Process startup speed must not decide whether renewal is unfinished.
      final pendingRefresh = await vendor.first;
      try {
        expect(
          await runtime!.close(timeout: const Duration(milliseconds: 1)),
          isFalse,
        );
        PluginRuntime? other;
        try {
          await expectLater(
            () async => other = await open(),
            throwsA(isA<PluginRuntimeFailure>()),
          );
        } finally {
          await other?.close();
        }
      } finally {
        await pendingRefresh.response.close();
      }
      expect((await renewal as Map)['renewed'], isTrue);
      expect(await runtime!.close(), isTrue);
      final saved = jsonDecode(
        await File('${directory.path}/plugin-auth.json').readAsString(),
      );
      expect(saved['fixture#a']['access'], 'fake-renewed');
      expect(saved['fixture#a']['refresh'], 'fake-next');
      runtime = await open();
    },
  );
}
