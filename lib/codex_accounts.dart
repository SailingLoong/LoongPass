import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum CodexAccountsIssue {
  unsupportedPlatform,
  runtimeUnavailable,
  unsupportedStore,
  restricted,
  unavailable,
}

enum CodexActivationOutcome { opened, applied, unchanged }

/// The native account owner is the only source of authentication facts. This
/// projection deliberately has no credential or raw native-response field.
class CodexAccountSummary {
  const CodexAccountSummary({
    required this.id,
    this.email,
    this.workspaceId,
    this.plan,
  });
  final String id;
  final String? email, workspaceId, plan;

  factory CodexAccountSummary.fromNative(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        (value['id'] as String).isEmpty) {
      throw const FormatException('Invalid Codex account summary');
    }
    return CodexAccountSummary(
      id: value['id'] as String,
      email: _optionalString(value['email']),
      workspaceId: _optionalString(value['workspaceId']),
      plan: _optionalString(value['plan']),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    if (email != null) 'email': email,
    if (workspaceId != null) 'workspaceId': workspaceId,
    if (plan != null) 'plan': plan,
  };
}

class CodexAccountsSnapshot {
  const CodexAccountsSnapshot({
    this.available = false,
    this.issue,
    this.accounts = const [],
    this.currentId,
    this.loginPending = false,
    this.busy = false,
    this.message,
    this.observedAt,
    this.outcome,
  });
  final bool available, loginPending, busy;
  final CodexAccountsIssue? issue;
  final List<CodexAccountSummary> accounts;

  /// Last identity observed in the local authentication file. This does not
  /// verify the running official client's online identity.
  final String? currentId;
  final String? message;
  final DateTime? observedAt;
  final CodexActivationOutcome? outcome;

  factory CodexAccountsSnapshot.fromNative(Object? value) {
    if (value is! Map ||
        value['available'] is! bool ||
        value['accounts'] is! List ||
        value['loginPending'] is! bool ||
        value['busy'] is! bool) {
      throw const FormatException('Invalid Codex accounts snapshot');
    }
    final issue = _optionalString(value['issue']);
    final observedAt = _optionalString(value['observedAt']);
    return CodexAccountsSnapshot(
      available: value['available'] == true,
      issue: issue == null
          ? null
          : CodexAccountsIssue.values
                    .where((v) => v.name == issue)
                    .firstOrNull ??
                CodexAccountsIssue.unavailable,
      accounts: List.unmodifiable(
        (value['accounts'] as List).map(CodexAccountSummary.fromNative),
      ),
      currentId: _optionalString(value['currentId']),
      loginPending: value['loginPending'] == true,
      busy: value['busy'] == true,
      message: _optionalString(value['message']),
      observedAt: observedAt == null ? null : DateTime.tryParse(observedAt),
      outcome: CodexActivationOutcome.values
          .where((v) => v.name == value['outcome'])
          .firstOrNull,
    );
  }

  Map<String, Object?> toJson() => {
    'available': available,
    if (issue != null) 'issue': issue!.name,
    'accounts': accounts.map((a) => a.toJson()).toList(),
    if (currentId != null) 'currentId': currentId,
    'loginPending': loginPending,
    'busy': busy,
    if (message != null) 'message': message,
    if (observedAt != null) 'observedAt': observedAt!.toIso8601String(),
    if (outcome != null) 'outcome': outcome!.name,
  };
}

String? _optionalString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// App-lifetime UI adapter. Native owns authorization jobs, observations and
/// renewal; polling only reads its existing projection and never refreshes auth.
/// Disposing a page or this adapter does not cancel a native authorization job.
class CodexAccounts extends ChangeNotifier {
  CodexAccounts({
    MethodChannel channel = const MethodChannel(
      'com.sailingloong.loongpass/files',
    ),
    TargetPlatform? platform,
  }) : _channel = channel,
       supported =
           !kIsWeb &&
           (platform ?? defaultTargetPlatform) == TargetPlatform.macOS {
    if (!supported) {
      _snapshot = const CodexAccountsSnapshot(
        issue: CodexAccountsIssue.unsupportedPlatform,
      );
      _hasSnapshot = true;
    }
  }

  final MethodChannel _channel;
  final bool supported;
  CodexAccountsSnapshot _snapshot = const CodexAccountsSnapshot();
  CodexAccountsSnapshot get snapshot => _snapshot;
  Timer? _poll;
  bool _disposed = false, _started = false, _reading = false;
  bool _mutating = false, _hasSnapshot = false;
  int _revision = 0;
  String? _error;
  String? get error => _error;
  bool get hasSnapshot => _hasSnapshot;
  bool get reading => _reading;
  bool get available => supported && _snapshot.available && _error == null;
  bool get busy => _mutating || _snapshot.busy;
  bool get canMutate =>
      !_disposed && available && !busy && !_snapshot.loginPending;
  bool get canCancelLogin =>
      !_disposed && supported && _snapshot.loginPending && !_mutating;

  Future<void> start() async {
    if (_disposed || _started || !supported) return;
    _started = true;
    await refreshSnapshot();
    if (!_disposed) {
      _poll = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(refreshSnapshot());
      });
    }
  }

  Future<void> refreshSnapshot() async {
    if (_disposed || !supported || _reading || _mutating) return;
    _reading = true;
    final revision = _revision;
    _notify();
    try {
      final value = await _channel.invokeMethod<Object?>('codexAccountsStatus');
      if (!_disposed && revision == _revision) _apply(value);
    } catch (_) {
      if (!_disposed && revision == _revision) {
        _error = '未能读取 Codex 账号记录，请稍后刷新。';
        _hasSnapshot = true;
      }
    } finally {
      _reading = false;
      _notify();
    }
  }

  Future<void> importCurrent() => _mutate('codexImportCurrent');
  Future<void> startLogin() => _mutate('codexStartLogin');
  Future<void> cancelLogin() => _mutate('codexCancelLogin', cancel: true);
  Future<void> activate(String id) => _mutate('codexActivate', id: id);
  Future<void> remove(String id) => _mutate('codexRemove', id: id);

  Future<void> _mutate(String method, {String? id, bool cancel = false}) async {
    if (!(cancel ? canCancelLogin : canMutate)) return;
    if (id != null && !_snapshot.accounts.any((a) => a.id == id)) return;
    _mutating = true;
    _revision++;
    _error = null;
    _notify();
    try {
      final value = await _channel.invokeMethod<Object?>(
        method,
        id == null ? null : {'id': id},
      );
      if (!_disposed) _apply(value);
    } catch (_) {
      // PlatformException text/details can contain process output or auth data.
      // Only the native snapshot's explicitly sanitized message is displayed.
      if (!_disposed) _error = 'Codex 操作结果未能确认，请刷新记录后核对。';
    } finally {
      _mutating = false;
      _notify();
    }
  }

  void _apply(Object? value) {
    _snapshot = CodexAccountsSnapshot.fromNative(value);
    _hasSnapshot = true;
    _error = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _poll?.cancel();
    super.dispose();
  }
}
