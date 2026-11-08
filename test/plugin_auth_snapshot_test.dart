import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/plugin_account_migration.dart';
import '../lib/plugin_accounts.dart';
import '../lib/plugin_credentials.dart';
import '../lib/plugin_migration.dart';
import '../lib/plugin_runtime.dart';
import 'memory_account_store.dart';

void main() {
  final sources = <String, dynamic>{
    'MiniMax-cn': {
      'accounts': {
        'legacy': {
          'uid': 'official',
          'accessToken': 'legacy-access',
          'refreshToken': '',
          'expiresAtMs': 0,
        },
      },
    },
  };

  Future<PluginRuntime> start(Directory root) => PluginRuntime.start(
    executable: Platform.environment['LOONGPASS_BUN'] ?? 'bun',
    hostPath:
        Platform.environment['LOONGPASS_AUTH_SNAPSHOT_HOST'] ??
        File('runtime/vendor/magpie/host.js').absolute.path,
    launcherPath: File('runtime/launcher.mjs').absolute.path,
    directory: root.path,
    plugins: [
      {
        'spec': 'fixture',
        'target': File('test/fixtures/native_plugin.mjs').absolute.path,
        'options': {'provider': 'minimax-code'},
      },
    ],
  );

  test(
    'migration and account reads retain the native recovered grant',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'loongpass-auth-recovery-',
      );
      final runtime = await start(root);
      PluginAccounts? accounts;
      try {
        final migrated = convertPluginAccounts(sources).single;
        final primary = File('${root.path}/plugin-auth.json');
        final recovered = {
          ...migrated.auth!,
          'access': 'native-rotated-access',
        };
        await primary.writeAsString('{truncated');
        await File('${primary.path}.bak')
            .writeAsString(jsonEncode({migrated.key: recovered}));
        final facts = MemoryAccountStore('facts');
        var retired = false;
        await PluginMigration(
          runtime: runtime,
          directory: root.path,
          backup: MemoryAccountStore('backup'),
          facts: facts,
          retireSources: (_) async {
            retired = true;
          },
        ).run(() async => sources);
        expect(retired, true);
        expect(
          (await PluginCredentials(runtime).account(migrated.key))['access'],
          'native-rotated-access',
        );
        accounts = PluginAccounts(
          runtime: runtime,
          directory: root.path,
          store: facts,
          enabledProviders: {'minimax-code'},
        );
        await accounts.start();
        expect(accounts.accounts.single.active, true);
        expect(accounts.accounts.single.models, isNotEmpty);
        expect(
          (await accounts.currentCredential(migrated.key))['access'],
          'native-rotated-access',
        );
        expect(await primary.readAsString(), '{truncated');
      } finally {
        await accounts?.close();
        await runtime.close();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'unknown native storage cannot retire sources or import over them',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'loongpass-auth-unknown-',
      );
      final runtime = await start(root);
      try {
        expect(await PluginCredentials(runtime).all(), isEmpty);
        final primary = File('${root.path}/plugin-auth.json');
        final backup = File('${primary.path}.bak');
        await primary.writeAsString('{truncated');
        await backup.writeAsString('{also-truncated');
        final archive = MemoryAccountStore('archive');
        final facts = MemoryAccountStore('facts');
        var retired = false, prepared = false;
        await expectLater(
          PluginMigration(
            runtime: runtime,
            directory: root.path,
            backup: archive,
            facts: facts,
            retireSources: (_) async {
              retired = true;
            },
            prepareCredential: (account) async {
              prepared = true;
              return account.auth;
            },
          ).run(() async => sources),
          throwsA(isA<PluginRuntimeFailure>()),
        );
        expect(retired, false);
        expect(prepared, false);
        expect(archive.data, isEmpty);
        expect(facts.data, isEmpty);
        expect(await primary.readAsString(), '{truncated');
        expect(await backup.readAsString(), '{also-truncated');
      } finally {
        await runtime.close();
        await root.delete(recursive: true);
      }
    },
  );
}
