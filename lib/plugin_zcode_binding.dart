import 'plugin_accounts.dart';

String? zcodeBindingLabel(
  PluginAccount account,
  Iterable<PluginAccount> accounts,
) {
  final device = account.zcodeDevice;
  if (device == null) return null;
  final owners = {
    for (final other in accounts)
      if (other.active && other.zcodeDevice == device && other.uid.isNotEmpty)
        zcodeRewardIdentity(other.realm, other.uid),
  };
  return owners.length > 1 ? '$device · ${owners.length} 个账号共用' : device;
}
