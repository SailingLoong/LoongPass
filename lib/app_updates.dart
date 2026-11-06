import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Read-only projection of Sparkle's state. Native Sparkle owns scheduling,
/// preferences, verification and installation; rendering never checks a feed.
class AppUpdates extends ChangeNotifier {
  static const _channel = MethodChannel('com.sailingloong.loongpass/updates');
  String? version, error;
  bool automaticChecks = false, automaticDownloads = false, canCheck = false;
  bool _disposed = false, _busy = false;
  bool get available => version != null && !_busy;

  Future<void> load() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stateChanged') _apply(call.arguments);
    });
    await _invoke('state');
  }

  void _apply(dynamic value) {
    if (_disposed || value is! Map) return;
    version = value['version'] as String?;
    automaticChecks = value['automaticChecks'] == true;
    automaticDownloads = value['automaticDownloads'] == true;
    canCheck = value['canCheck'] == true;
    error = null;
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

  Future<void> check() => _invoke('check');
  Future<void> setAutomaticChecks(bool value) =>
      _invoke('setAutomaticChecks', value);
  Future<void> setAutomaticDownloads(bool value) =>
      _invoke('setAutomaticDownloads', value);
  @override
  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}

class AppUpdateCard extends StatelessWidget {
  const AppUpdateCard({super.key, required this.updates});
  final AppUpdates updates;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: updates,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('应用更新', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(updates.version == null ? '正在读取版本信息' : '当前版本 ${updates.version}'),
        const Text('公开测试版更新，保留本机账号和设置。'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('自动检查更新'),
          value: updates.automaticChecks,
          onChanged: updates.available ? updates.setAutomaticChecks : null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('自动下载更新'),
          subtitle: const Text('校验通过后在退出时安装，也可以主动安装并重启。'),
          value: updates.automaticDownloads,
          onChanged: updates.available && updates.automaticChecks
              ? updates.setAutomaticDownloads
              : null,
        ),
        if (updates.error != null) Text(updates.error!),
        OutlinedButton.icon(
          onPressed: updates.available && updates.canCheck
              ? updates.check
              : null,
          icon: const Icon(Icons.system_update_alt, size: 17),
          label: const Text('检查更新'),
        ),
      ],
    ),
  );
}
