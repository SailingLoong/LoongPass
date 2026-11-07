import 'rewards/reward_providers.dart';

/// Stable identity and presentation metadata, independent of sidebar ordering.
/// Additional reward platforms are derived from their protocol registration.
class ManagedApp {
  const ManagedApp._(
    this.name,
    this.label,
    this.region,
    this.regionCode, {
    String? iconName,
  }) : _iconName = iconName;
  static const zcode = ManagedApp._('zcode', 'ZCode', '智谱 BigModel', 'CN');
  static const qoderCn = ManagedApp._(
    'qoderCn',
    'Qoder CN',
    '国内版',
    'CN',
    iconName: 'qoder',
  );
  static const qoder = ManagedApp._('qoder', 'Qoder', '海外版', 'GL');
  static const minimaxCn = ManagedApp._(
    'minimaxCn',
    'MiniMax CN',
    '国内版',
    'CN',
    iconName: 'minimax',
  );
  static const minimax = ManagedApp._('minimax', 'MiniMax', '海外版', 'GL');
  static const workbuddy = ManagedApp._('workbuddy', 'WorkBuddy', '国内版', 'CN');
  static const traeCn = ManagedApp._(
    'traeCn',
    'TRAE CN',
    '国内版',
    'CN',
    iconName: 'trae',
  );
  static final values = List<ManagedApp>.unmodifiable([
    zcode,
    qoderCn,
    qoder,
    minimaxCn,
    minimax,
    workbuddy,
    traeCn,
    for (final provider in rewardProviders)
      ManagedApp._(
        provider.id,
        provider.label,
        provider.region,
        provider.regionCode,
      ),
  ]);
  final String name, label, region, regionCode;
  final String? _iconName;
  String get iconAsset => 'assets/app_icons/${_iconName ?? name}.png';
  int get index => values.indexOf(this);
}
