import 'dart:convert';

import 'plugin_accounts.dart';
import 'zcode_api.dart';

/// Reserves only an existing, unoccupied device for an explicit native login.
/// It never changes credentials or treats selection as a successful rebind.
class ZcodeDeviceReservation {
  ZcodeDeviceReservation._(this.device, this._lease);
  final String device, _lease;
  static final _reserved = <String>{};
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _reserved.remove(_lease);
  }

  static Future<ZcodeDeviceReservation> take(
    PluginAccounts accounts,
    PluginAccount target,
  ) async {
    final native = await accounts.credentials.all();
    final data = (await accounts.store.read()).data;
    final row = (data['accounts'] as Map? ?? {})[target.key];
    final live = accounts.accounts
        .where((a) => a.key == target.key)
        .firstOrNull;
    final auth = native[target.key];
    final state = auth?['type'] == 'oauth'
        ? jsonDecode(auth!['refresh'] as String)
        : null;
    if (target.provider != 'zcode' ||
        target.uid.isEmpty ||
        live?.registrationId != target.registrationId ||
        row is! Map ||
        row['removed'] == true ||
        row['registrationId'] != target.registrationId ||
        row['uid'] != target.uid ||
        row['realm'] != target.realm ||
        auth?['uid'] != target.uid ||
        state is! Map ||
        state['site'] != target.realm) {
      throw const ZcodeFailure('binding_changed');
    }
    final occupied = <String>{};
    for (final entry in native.entries) {
      if (entry.key.split('#').first != 'zcode' ||
          entry.value['type'] != 'oauth')
        continue;
      final saved = jsonDecode(entry.value['refresh'] as String);
      occupied.add(zcodeDeviceId(saved['device']));
    }
    void observe(Object? value) {
      if (value == null) return;
      if (value is! Map) throw const ZcodeFailure('storage_unavailable');
      final context = value['context'];
      if (context != null) occupied.add(zcodeDeviceId(context['deviceMid']));
      final history = value['bindingHistory'];
      if (history != null) {
        if (history is! List) throw const ZcodeFailure('storage_unavailable');
        for (final binding in history) {
          observe(binding);
        }
      }
    }

    for (final saved in (data['accounts'] as Map? ?? {}).values) {
      if (saved['provider'] != 'zcode') continue;
      observe(saved['legacy']);
      observe(saved['reward']);
    }
    for (final reward in (data['zcode']?['rewards'] as Map? ?? {}).values) {
      observe(reward);
    }
    final pool = data['zcode']?['devicePool'] ?? <String>[];
    if (pool is! List || pool.length > 100)
      throw const ZcodeFailure('storage_unavailable');
    final devices = pool.map(zcodeDeviceId).toList();
    if (devices.toSet().length != devices.length)
      throw const ZcodeFailure('storage_unavailable');
    for (final device in devices) {
      final lease = '${accounts.store.identity}\u0000$device';
      if (!occupied.contains(device) && _reserved.add(lease)) {
        return ZcodeDeviceReservation._(device, lease);
      }
    }
    throw const ZcodeFailure('device_pool_empty');
  }
}
