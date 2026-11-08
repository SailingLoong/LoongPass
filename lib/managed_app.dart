/// Stable identity and presentation metadata, independent of sidebar ordering.
/// Native provider membership is declared once with each product entry.
class ManagedApp {
  const ManagedApp._(
    this.name,
    this.label,
    this.region,
    this.regionCode, {
    String? iconName,
    this.nativeProviders = const {},
  }) : _iconName = iconName;
  static const zcode = ManagedApp._(
    'zcode',
    'ZCode',
    '智谱 BigModel',
    'CN',
    nativeProviders: {'zcode'},
  );
  static const qoderCn = ManagedApp._(
    'qoderCn',
    'Qoder CN',
    '国内版',
    'CN',
    iconName: 'qoder',
    nativeProviders: {'qoder-cn'},
  );
  static const qoder = ManagedApp._(
    'qoder',
    'Qoder',
    '海外版',
    'GL',
    nativeProviders: {'qoder'},
  );
  static const minimaxCn = ManagedApp._(
    'minimaxCn',
    'MiniMax CN',
    '国内版',
    'CN',
    iconName: 'minimax',
    nativeProviders: {'minimax-code'},
  );
  static const minimax = ManagedApp._(
    'minimax',
    'MiniMax',
    '海外版',
    'GL',
    nativeProviders: {'minimax-code-global'},
  );
  static const workbuddy = ManagedApp._(
    'workbuddy',
    'WorkBuddy',
    '国内版',
    'CN',
    nativeProviders: {'workbuddy'},
  );
  static const traeCn = ManagedApp._(
    'traeCn',
    'TRAE CN',
    '国内版',
    'CN',
    iconName: 'trae',
    nativeProviders: {'trae-cn'},
  );
  static const loomy = ManagedApp._(
    'loomy',
    'Loomy',
    '国内版',
    'CN',
    nativeProviders: {'loomy'},
  );
  static const codex = ManagedApp._('codex', 'Codex', '官方账号', 'GL');
  static final values = List<ManagedApp>.unmodifiable([
    zcode,
    qoderCn,
    qoder,
    minimaxCn,
    minimax,
    workbuddy,
    traeCn,
    loomy,
    codex,
  ]);
  final String name, label, region, regionCode;
  final Set<String> nativeProviders;
  final String? _iconName;
  String get iconAsset => 'assets/app_icons/${_iconName ?? name}.png';
  int get index => values.indexOf(this);
}
