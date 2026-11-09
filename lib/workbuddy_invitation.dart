import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Owns the user's invitation override. Official WorkBuddy owns all binding
/// and reward eligibility decisions.
class WorkBuddyInvitation extends ChangeNotifier {
  WorkBuddyInvitation({this.read, this.write}) : ready = read == null;

  factory WorkBuddyInvitation.persistent() {
    final store = SharedPreferencesAsync();
    const key = 'loongpass.workbuddy.invitationCode';
    return WorkBuddyInvitation(
      read: () => store.getString(key),
      write: (value) => store.setString(key, value),
    );
  }

  static const defaultCode = '3wu5mr8ye2b0';
  final Future<String?> Function()? read;
  final Future<void> Function(String)? write;
  String _overrideCode = '';
  Future<void> _pending = Future.value();
  bool ready;
  String? error;
  bool _disposed = false;
  int _revision = 0;

  String get overrideCode => _overrideCode;
  Uri get url => Uri.https('www.workbuddy.cn', '/events/invite/', {
    'inviteCode': _overrideCode.isEmpty ? defaultCode : _overrideCode,
  });

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
