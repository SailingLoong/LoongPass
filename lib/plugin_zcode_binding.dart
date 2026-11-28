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

typedef ZcodeBindingOptions = ({bool conflict, bool canSwitch});

ZcodeBindingOptions zcodeBindingOptions(
  PluginAccount account,
  Iterable<PluginAccount> accounts,
  String? localDevice,
) {
  final conflict = zcodeBindingConflicts(account, accounts);
  final available =
      account.zcodeBinding != null &&
      localDevice != null &&
      localDevice != account.zcodeDevice &&
      !zcodeBindingConflicts(account, accounts, device: localDevice);
  return (conflict: conflict, canSwitch: available);
}

const zcodeBindingGuidance = '设备绑定与其他已保存账号冲突。';
const zcodeNoAlternative = '设备绑定冲突，暂无可切换设备';

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
