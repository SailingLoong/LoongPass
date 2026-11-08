import 'plugin_runtime.dart';

/// Read-only snapshots of the native owner's storage and recovery decision.
/// UI DTOs and model catalogs must never include this material.
class PluginCredentials {
  PluginCredentials(this.runtime);
  final PluginRuntime runtime;
  Future<Map<String, Map<String, dynamic>>> all() async {
    final value = await runtime.call('authSnapshot', {});
    if (value is! Map<String, dynamic>)
      throw const FormatException('Invalid credential store');
    return {
      for (final e in value.entries)
        e.key: Map<String, dynamic>.from(e.value as Map),
    };
  }

  Future<Map<String, dynamic>> account(String key) async {
    final account = (await all())[key];
    if (account == null) throw const FormatException('Account is signed out');
    return account;
  }
}
