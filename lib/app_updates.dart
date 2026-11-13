import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'update_contract.dart';
export 'app_update_view.dart' show AppUpdateCard, AppUpdateBadge;
export 'update_contract.dart' show UpdatePhase;

/// A one-way projection. Native engines own scheduling, downloads and install.
class AppUpdates extends ChangeNotifier {
  static const _channel = MethodChannel(UpdateContract.channel);
  String? version, offeredVersion, error;
  UpdatePhase phase = UpdatePhase.idle;
  double? progress;
  bool automaticUpdates = false, receiveBetaUpdates = false;
  bool canCheck = false, canChangeChannel = false, installOnQuit = true;
  bool _canInstall = false, _canSkip = false;
  bool _disposed = false, _busy = false;
  int _revision = -1;
  bool get available => version != null && !_busy;
  bool get canInstall => available && _canInstall && phase == UpdatePhase.ready;
  bool get canSkip => available && _canSkip;

  Future<void> load() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == UpdateContract.stateChanged) _apply(call.arguments);
    });
    await _invoke(UpdateContract.state);
  }

  void _apply(dynamic value) {
    if (_disposed || value is! Map) return;
    final revision = value[UpdateContract.revision] as int? ?? 0;
    if (revision < _revision) return;
    _revision = revision;
    version = value[UpdateContract.version] as String?;
    offeredVersion = value[UpdateContract.offeredVersion] as String?;
    phase = UpdatePhase.values.firstWhere(
      (phase) => phase.name == value[UpdateContract.phase],
      orElse: () => UpdatePhase.idle,
    );
    final fraction = value[UpdateContract.progress] as num?;
    progress = fraction != null && fraction.isFinite
        ? fraction.toDouble().clamp(0, 1)
        : null;
    automaticUpdates = value[UpdateContract.automaticUpdates] == true;
    receiveBetaUpdates = value[UpdateContract.receiveBetaUpdates] == true;
    canCheck = value[UpdateContract.canCheck] == true;
    installOnQuit = value[UpdateContract.installOnQuit] != false;
    canChangeChannel = value[UpdateContract.canChangeChannel] == true;
    _canInstall = value[UpdateContract.canInstall] == true;
    _canSkip = value[UpdateContract.canSkip] == true;
    error = value[UpdateContract.error] as String?;
    notifyListeners();
  }

  Future<void> _invoke(String method, [Object? value]) async {
    if (_disposed || _busy) return;
    _busy = true;
    notifyListeners();
    try {
      _apply(await _channel.invokeMethod<Object?>(method, value));
    } catch (_) {
      if (!_disposed) error = '更新操作未完成，请稍后重试。';
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> check() =>
      canCheck ? _invoke(UpdateContract.check) : Future.value();
  Future<void> install() =>
      canInstall ? _invoke(UpdateContract.install) : Future.value();
  Future<void> skip() =>
      canSkip ? _invoke(UpdateContract.skip) : Future.value();
  Future<void> setAutomaticUpdates(bool value) =>
      _invoke(UpdateContract.setAutomaticUpdates, value);
  Future<void> setReceiveBetaUpdates(bool value) =>
      _invoke(UpdateContract.setReceiveBetaUpdates, value);

  @override
  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
