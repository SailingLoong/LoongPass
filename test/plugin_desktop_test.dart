import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/plugin_runtime.dart';
import '../lib/plugin_accounts.dart';
import '../lib/workbuddy_plugin_features.dart';
import '../lib/workbuddy_api.dart';
import 'memory_account_store.dart';

void main() {
  test('desktop activation verifies the full profile using the current native grant', () async {
    final root = await Directory.systemTemp.createTemp('loongpass-desktop-');
    final runtime = await PluginRuntime.start(
      executable: Platform.environment['LOONGPASS_BUN'] ?? 'bun',
      hostPath: File('runtime/vendor/magpie/host.js').absolute.path,
      launcherPath: File('runtime/launcher.mjs').absolute.path,
      directory: root.path,
      plugins: [
        {
          'spec': 'fixture',
          'target': File('test/fixtures/native_plugin.mjs').absolute.path,
          'options': {'provider': 'workbuddy'},
        },
      ],
    );
    final accounts = PluginAccounts(
      runtime: runtime,
      directory: root.path,
      store: MemoryAccountStore('fixture'),
      enabledProviders: {'workbuddy'},
    );
    try {
      await runtime.call('import', {
        'provider': 'workbuddy',
        'key': 'workbuddy#a',
        'auth': {
          'type': 'oauth',
          'uid': 'official-a',
          'accountId': 'masked-name',
          'domain': 'www.workbuddy.cn',
          'access': 'current-native-access',
          'refresh': '',
          'expires': 0,
        },
      });
      await accounts.start();
      final exchange = _ProfileExchange();
      final features = WorkBuddyPluginFeatures(accounts, exchange: exchange);
      var applied = 0;
      final result = await features.activate(
        'workbuddy#a',
        apply: (session) async {
          final message = session.nativeMessage();
          expect(message['account'], {
            'uid': 'official-a',
            'type': 'personal',
            'name': 'Full official profile',
          });
          expect(
            (message['auth'] as Map)['accessToken'],
            'current-native-access',
          );
          applied++;
          return 'applied';
        },
      );
      expect(result, 'applied');
      expect(exchange.token, 'Bearer current-native-access');
      exchange.uid = 'another-user';
      await expectLater(
        features.activate(
          'workbuddy#a',
          apply: (_) async {
            applied++;
            return 'applied';
          },
        ),
        throwsA(isA<WorkBuddyApiFailure>()),
      );
      expect(applied, 1);
      exchange.uid = 'official-a';
      for (final profile in <Map<String, Object?>>[
        {'uid': 'official-a'},
        {'uid': 'official-a', 'type': 'enterprise'},
        {
          'uid': 'official-a',
          'type': 'personal',
          'enterpriseId': 'another-scope',
        },
        {'uid': 'official-a', 'type': 'personal', 'domain': 'www.codebuddy.cn'},
      ]) {
        exchange.profile = profile;
        await expectLater(
          features.activate(
            'workbuddy#a',
            apply: (_) async {
              applied++;
              return 'applied';
            },
          ),
          throwsA(isA<WorkBuddyApiFailure>()),
        );
      }
      expect(
        applied,
        1,
        reason:
            'An incomplete or different profile cannot activate the desktop',
      );
    } finally {
      await accounts.close();
      await runtime.close();
      await root.delete(recursive: true);
    }
  });
}

class _ProfileExchange implements WorkBuddyExchange {
  String uid = 'official-a', token = '';
  Map<String, Object?>? profile;
  @override
  Future<Map<String, Object?>> send(
    WorkBuddyRequest request,
    bool Function() admitted,
  ) async {
    expect(admitted(), true);
    expect(
      request.uri.toString(),
      'https://www.workbuddy.cn/v2/plugin/account',
    );
    expect(request.method, 'GET');
    token = request.headers['Authorization']!;
    return {
      'code': 0,
      'data':
          profile ??
          {'uid': uid, 'type': 'personal', 'name': 'Full official profile'},
    };
  }
}
