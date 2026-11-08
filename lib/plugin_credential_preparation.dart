import 'dart:convert';
import 'dart:io';

import 'plugin_account_migration.dart';

/// The only legacy format that needs acquisition is Qoder's global device
/// grant. Reuse the same native exchange as fresh authorization; never rotate
/// the device refresh token from the migration process.
class PluginCredentialPreparation {
  PluginCredentialPreparation(this.executable, this.script);
  final String executable, script;

  Future<Map<String, dynamic>?> call(MigratedPluginAccount account) async {
    if (account.provider != 'qoder' || account.auth == null)
      return account.auth;
    final child = await Process.start(executable, [script]);
    final output = child.stdout.transform(utf8.decoder).join();
    final errors = child.stderr.drain<void>();
    child.stdin.write(
      jsonEncode({'provider': account.provider, 'auth': account.auth}),
    );
    await child.stdin.close();
    try {
      final exit = await child.exitCode.timeout(const Duration(seconds: 45));
      await errors;
      final result = jsonDecode(await output) as Map;
      if (exit != 0) throw StateError('Native credential conversion failed');
      if (result['ok'] == true)
        return Map<String, dynamic>.from(result['auth']);
      if (result['rejected'] == true) return null;
      throw StateError(
        'Qoder authorization conversion is temporarily unavailable',
      );
    } finally {
      child.kill();
    }
  }
}
