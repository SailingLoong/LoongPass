import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'managed_app.dart';

/// Owns each platform's invitation override. The official platform owns binding
/// and reward eligibility decisions.
class InvitationSettings extends ChangeNotifier {
  InvitationSettings(this.app, {this.read, this.write}) : ready = read == null {
    if (!_programs.containsKey(app)) throw ArgumentError.value(app, 'app');
  }

  factory InvitationSettings.persistent(ManagedApp app) {
    final store = SharedPreferencesAsync();
    final key = 'loongpass.${app.name}.invitationCode';
    return InvitationSettings(
      app,
      read: () => store.getString(key),
      write: (value) => store.setString(key, value),
    );
  }

  static const _programs = {
    ManagedApp.workbuddy: (
      defaultCode: '3wu5mr8ye2b0',
      host: 'www.workbuddy.cn',
      path: '/events/invite/',
      parameter: 'inviteCode',
    ),
    ManagedApp.qoderCn: (
      defaultCode: 'n1SqSmAhYt8nJKTkFM2QyB5IJ0DWROl3',
      host: 'qoder.cn',
      path: '/activities',
      parameter: 'referral_code',
    ),
  };
  static Iterable<ManagedApp> get platforms => _programs.keys;
  final ManagedApp app;
  final Future<String?> Function()? read;
  final Future<void> Function(String)? write;
  String _overrideCode = '';
  Future<void> _pending = Future.value();
  bool ready;
  String? error;
  bool _disposed = false;
  int _revision = 0;

  String get overrideCode => _overrideCode;
  String get defaultCode => _programs[app]!.defaultCode;
  Uri get url {
    final program = _programs[app]!;
    return Uri.https(program.host, program.path, {
      program.parameter: _overrideCode.isEmpty
          ? program.defaultCode
          : _overrideCode,
    });
  }

  Future<void> load() async {
    final revision = _revision;
    try {
      final value = await read?.call();
      if (_disposed || revision != _revision) return;
      _overrideCode = value?.trim() ?? '';
      ready = true;
      error = null;
    } catch (_) {
      if (_disposed || revision != _revision) return;
      error = '邀请码未能读取，请重试。';
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> save(String value) {
    final code = value.trim();
    if (!ready) return Future.error(StateError('Settings unavailable'));
    if (code.isNotEmpty && !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(code)) {
      return Future.error(const FormatException('Invalid invitation code'));
    }
    _revision++;
    final operation = _pending.then((_) async {
      await write?.call(code);
      if (_disposed) return;
      _overrideCode = code;
      error = null;
      notifyListeners();
    });
    _pending = operation.catchError((Object _) {});
    return operation;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
