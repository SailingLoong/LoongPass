import 'dart:io';

import 'package:flutter/services.dart';

import 'managed_app.dart';
import 'model_connection.dart';
import 'native_account_document_store.dart';
import 'native_legacy_sources.dart';
import 'pinned_bun.dart';
import 'plugin_accounts.dart';
import 'plugin_credential_preparation.dart';
import 'plugin_installation.dart';
import 'plugin_migration.dart';
import 'plugin_model_service.dart';
import 'plugin_rewards.dart';
import 'plugin_runtime.dart';
import 'plugin_zcode_rewards.dart';
import 'workbuddy_plugin_features.dart';
import 'workbuddy_desktop_flutter.dart';
import 'zcode_api.dart';

/// Product entries select native providers; their protocols stay in the pinned
/// packages. Codex's official desktop account owner remains independent.
Set<String> providersForApp(ManagedApp app) => app.nativeProviders;

class PluginApplication {
  PluginApplication._(
    this.installation,
    this.runtime,
    this.accounts,
    this.models,
    this.rewards,
    this.connection,
  );
  final PluginInstallation installation;
  final PluginRuntime runtime;
  final PluginAccounts accounts;
  final PluginModelService models;
  final PluginRewards rewards;
  final ModelConnection connection;
  String get bridgePath => installation.bridgePath;

  static Future<PluginApplication> start() async {
    final root = await NativeAccountDocumentStore('PluginRuntime')
        .privateDirectory();
    final installation = await PluginInstallation.prepare(root, (name) async {
      final bytes = await rootBundle.load(name);
      return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    });
    await installation.publishBridge();
    final cache = Platform.isMacOS
        ? '${Platform.environment['HOME']}/Library/Caches/LoongPass/native-plugin-runtime'
        : '${Platform.environment['LOCALAPPDATA']}/LoongPass/NativePluginRuntime';
    final bun = await PinnedBun.prepare(
      cache,
      Map<String, dynamic>.from(installation.manifest['bun']),
    );
    final runtime = await PluginRuntime.start(
      executable: bun,
      hostPath: installation.hostPath,
      launcherPath: installation.launcherPath,
      directory: root,
      plugins: installation.plugins,
    );
    PluginAccounts? accounts;
    PluginModelService? models;
    PluginRewards? rewards;
    try {
      final sources = nativeLegacySources();
      final facts = NativeAccountDocumentStore('PluginAccounts');
      await PluginMigration(
        runtime: runtime,
        directory: root,
        backup: NativeAccountDocumentStore('PluginMigration'),
        facts: facts,
        retireSources: sources.retire,
        prepareCredential: PluginCredentialPreparation(
          bun,
          '${installation.codePath}/migrate.mjs',
        ).call,
      ).run(sources.read);
      accounts = PluginAccounts(
        runtime: runtime,
        directory: root,
        store: facts,
        enabledProviders: ManagedApp.values
            .expand((a) => a.nativeProviders)
            .toSet(),
      );
      await accounts.start();
      models = PluginModelService(
        accounts: accounts,
        store: NativeAccountDocumentStore('ModelService'),
      );
      await models.start();
      rewards = PluginRewards(
        accounts,
        zcode: PluginZcodeRewards(
          accounts,
          contextFor: (account, auth) async {
            final context = await runtime.call('rewardContext', {
              'provider': account.provider,
              'account': account.key,
            });
            if (context is! Map) throw const ZcodeFailure('device_required');
            return zcodeContext(Map<String, dynamic>.from(context));
          },
        ),
      );
      await rewards.start();
      return PluginApplication._(
        installation,
        runtime,
        accounts,
        models,
        rewards,
        ModelConnection(models, installation.bridgePath),
      );
    } catch (_) {
      await rewards?.close();
      await models?.close();
      await accounts?.close();
      await runtime.close();
      rethrow;
    }
  }

  Future<String> activateWorkBuddy(String key) =>
      WorkBuddyPluginFeatures(accounts)
          .activate(key, apply: WorkBuddyDesktopFlutter.activate);
  Future<void> close() async {
    connection.dispose();
    await rewards.close();
    await models.close();
    await accounts.close();
    await runtime.close();
  }
}
