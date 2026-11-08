import 'plugin_runtime.dart';
import 'account_document_store.dart';
import 'plugin_account_migration.dart';
import 'plugin_credentials.dart';

/// The backup is committed before retiring the former credential owners.
/// Restart reads that backup and the native store; it never reimports a grant
/// that the host may already have rotated after a lost acknowledgement.
class PluginMigration {
  PluginMigration({
    required this.runtime,
    required String directory,
    required this.backup,
    required this.facts,
    required this.retireSources,
    this.prepareCredential,
  }) : credentials = PluginCredentials(runtime);
  final PluginRuntime runtime;
  final PluginCredentials credentials;
  final AccountDocumentStore backup, facts;
  final Future<void> Function(Map<String, dynamic>) retireSources;
  final Future<Map<String, dynamic>?> Function(MigratedPluginAccount)?
  prepareCredential;

  Future<void> run(Future<Map<String, dynamic>> Function() readSources) async {
    final metadata = await facts.read();
    if (metadata.data['migrationComplete'] == true) return;
    // An unreadable native store must never be mistaken for a new install.
    // Check before preparing grants or retiring the former credential owners.
    await credentials.all();
    var frozen = await backup.read();
    if (frozen.data.isEmpty) {
      final sources = await readSources();
      convertPluginAccounts(
        sources,
      ); // Validate every record before any change.
      await backup.write(frozen.revision, {
        'version': 1,
        'sources': sources,
        'retired': false,
      });
      frozen = await backup.read();
    }
    if (frozen.data['version'] != 1 ||
        frozen.data['sources'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid migration archive');
    }
    final sources = frozen.data['sources'] as Map<String, dynamic>;
    final accounts = convertPluginAccounts(sources);
    final prepared = Map<String, dynamic>.from(
      frozen.data['prepared'] as Map? ?? {},
    );
    for (final account in accounts) {
      if (account.auth == null || prepared.containsKey(account.key)) continue;
      if (account.provider == 'qoder' && prepareCredential == null) {
        throw StateError('Qoder global requires native job-token acquisition');
      }
      prepared[account.key] = prepareCredential == null
          ? account.auth
          : await prepareCredential!(account);
      await backup.write(frozen.revision, {
        ...frozen.data,
        'prepared': prepared,
      });
      frozen = await backup.read();
    }
    if (frozen.data['retired'] != true) {
      await credentials.all();
      await retireSources(sources);
      await backup.write(frozen.revision, {...frozen.data, 'retired': true});
    }
    final rows = Map<String, dynamic>.from(
      metadata.data['accounts'] as Map? ?? {},
    );
    for (final account in accounts) {
      final current = (await credentials.all())[account.key];
      if (current != null &&
          (current['uid'] != account.auth?['uid'] || account.auth == null)) {
        throw const FormatException('Native identity conflicts with migration');
      }
      final auth = prepared[account.key];
      if (current == null && auth != null) {
        await runtime.call('import', {
          'provider': account.provider,
          'key': account.key,
          'auth': auth,
        });
      }
      rows.putIfAbsent(
        account.key,
        () => {
          ...account.facts,
          if (account.auth != null && auth == null)
            'quarantine': 'authorization_required',
        },
      );
    }
    await facts.write(metadata.revision, {
      ...metadata.data,
      'version': 1,
      'accounts': rows,
      'migrationComplete': true,
      'zcode': {
        if (sources['ZCode']?['devicePool'] != null)
          'devicePool': sources['ZCode']['devicePool'],
      },
    });
  }
}
