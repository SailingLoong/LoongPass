import 'plugin_accounts.dart';

String? zcodeBindingLabel(
  String? device,
  Iterable<PluginAccount> accounts, {
  bool selecting = false,
}) {
  if (device == null) return null;
  final owners = {
    for (final other in accounts)
      if (other.active && other.zcodeDevice == device && other.uid.isNotEmpty)
        zcodeRewardIdentity(other.realm, other.uid),
  };
  if (selecting && owners.isNotEmpty)
    return '$device · 已有 ${owners.length} 个账号绑定';
  return owners.length > 1 ? '$device · ${owners.length} 个账号共用' : device;
}
