import 'plugin_accounts.dart';

bool zcodeBindingConflicts(
  PluginAccount account,
  Iterable<PluginAccount> accounts, {
  String? device,
}) {
  final mid = device ?? account.zcodeDevice;
  if (mid == null ||
      !account.active ||
      account.provider != 'zcode' ||
      account.uid.isEmpty)
    return false;
  return zcodeDeviceConflict(
    (
      owner: zcodeRewardIdentity(account.realm, account.uid),
      device: mid.toLowerCase(),
    ),
    accounts
        .where((a) => a.key != account.key)
        .map((a) => a.zcodeBinding)
        .nonNulls,
  );
}

const zcodeBindingGuidance = '设备绑定冲突。请核对账号，在该账号实际使用的 ZCode 设备上重新授权。';

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
