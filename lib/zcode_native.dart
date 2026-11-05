/// Injectable native boundary. No credential material or native paths belong here.
///
/// This client does not discover accounts, stop processes, resolve keys, retry,
/// restore automatically, or enable UI controls. Native code owns those gates.
typedef ZcodeCall = Future<Object?> Function(
  String method,
  Map<String, Object?> arguments,
);

class ZcodeNativeFailure implements Exception {
  static const _codes = {
    'WritersActive',
    'SourceChanged',
    'UnsafePath',
    'InvalidCredential',
    'LockBusy',
    'Storage',
    'RecoveryChanged',
    'CommitUncertain',
    'NativeContextUnavailable',
    'NativeCaptureRequired',
    'InvalidArguments',
    'UnsupportedMethod',
    'UnknownAccount',
    'UnknownOperation',
    'Cancelled',
    // Dart-only transport/protocol failures, never raw native exception text.
    'InvalidReply',
    'InvalidResponse',
    'LoginExpired',
    'NativeUnavailable',
    'NativeFailure',
  };

  final String code;

  /// An operation may have reached publication. This is never rollback success.
  /// Do not automatically retry or restore after an uncertain outcome.
  final bool outcomeUnknown;
  const ZcodeNativeFailure._(this.code, {this.outcomeUnknown = false});
  factory ZcodeNativeFailure.fromCode(Object? code) {
    final safe = code is String && _codes.contains(code)
        ? code
        : 'NativeFailure';
    return ZcodeNativeFailure._(
      safe,
      outcomeUnknown: safe == 'CommitUncertain',
    );
  }
  @override
  String toString() => 'ZcodeNativeFailure($code)';
}

class ZcodeStatus {
  final bool available;
  final String? reason;
  const ZcodeStatus(this.available, this.reason);
}

class ZcodeCapture {
  final String accountId;
  final String revision;
  final String family;
  final String? label;
  const ZcodeCapture(this.accountId, this.revision, this.family, this.label);
}

class ZcodeReceipt {
  final String outcome;
  final String? operationId;
  const ZcodeReceipt(this.outcome, this.operationId);
}

class ZcodeNativeClient {
  final ZcodeCall _call;
  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');
  static final _unsafeLabel = RegExp(
    r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]',
  );

  ZcodeNativeClient({required ZcodeCall call}) : _call = call;

  Future<T> _invoke<T>(
    String method,
    Map<String, Object?> arguments,
    T Function(Object?) decode, {
    bool changesStorage = false,
  }) async {
    try {
      return decode(await _call(method, Map.unmodifiable(arguments)));
    } on ZcodeNativeFailure catch (failure) {
      if (changesStorage &&
          const {
            'CommitUncertain',
            'NativeFailure',
            'NativeUnavailable',
            'InvalidReply',
    'InvalidResponse',
    'LoginExpired',
          }.contains(failure.code)) {
        throw ZcodeNativeFailure._(failure.code, outcomeUnknown: true);
      }
      rethrow;
    } catch (_) {
      // The transport may have disconnected after a successful native write.
      // Never expose its potentially credential-bearing message or details.
      throw ZcodeNativeFailure._(
        'NativeUnavailable',
        outcomeUnknown: changesStorage,
      );
    }
  }

  static Never _invalidReply() =>
      throw const ZcodeNativeFailure._('InvalidReply');

  static Map<Object?, Object?> _reply(Object? value, Set<String> fields) {
    if (value is! Map || value.keys.any((key) => !fields.contains(key))) {
      _invalidReply();
    }
    return value;
  }

  static bool _handle(Object? value) =>
      value is String && value.length == 64 && _hex64.hasMatch(value);

  static ZcodeStatus _status(Object? value) {
    final map = _reply(value, {'available', 'reason'});
    final available = map['available'];
    final reason = map['reason'];
    if (available is! bool ||
        (reason != null &&
            (reason is! String ||
                !ZcodeNativeFailure._codes.contains(reason)))) {
      _invalidReply();
    }
    return ZcodeStatus(available, reason as String?);
  }

  static ZcodeCapture _capture(Object? value) {
    final map = _reply(value, {'accountId', 'revision', 'family', 'label'});
    final accountId = map['accountId'];
    final revision = map['revision'];
    final family = map['family'];
    final label = map['label'];
    if (!_handle(accountId) ||
        !_handle(revision) ||
        (family != 'zai' && family != 'bigmodel') ||
        (label != null &&
            (label is! String ||
                label.length > 256 ||
                _unsafeLabel.hasMatch(label)))) {
      _invalidReply();
    }
    return ZcodeCapture(
      accountId as String,
      revision as String,
      family as String,
      label as String?,
    );
  }

  static ZcodeReceipt _receipt(Object? value, String completed) {
    final map = _reply(value, {'outcome', 'operationId'});
    final outcome = map['outcome'];
    final operationId = map['operationId'];
    if ((outcome != completed && outcome != 'unchanged') ||
        (operationId != null && !_handle(operationId))) {
      _invalidReply();
    }
    return ZcodeReceipt(outcome as String, operationId as String?);
  }

  Future<ZcodeStatus> status() => _invoke('status', {}, _status);
  Future<ZcodeCapture> captureCurrent() =>
      _invoke('captureCurrent', {}, _capture);
  Future<ZcodeCapture> captureSelected() =>
      _invoke('captureSelected', {}, _capture);

  Future<ZcodeReceipt> switchAccount({
    required String accountId,
    required String expectedRevision,
  }) async {
    if (!_handle(accountId) || !_handle(expectedRevision)) {
      throw const ZcodeNativeFailure._('InvalidArguments');
    }
    return _invoke(
      'switchAccount',
      {'accountId': accountId, 'expectedRevision': expectedRevision},
      (value) => _receipt(value, 'switched'),
      changesStorage: true,
    );
  }

  Future<ZcodeReceipt> restore({required String operationId}) async {
    if (!_handle(operationId)) {
      throw const ZcodeNativeFailure._('InvalidArguments');
    }
    return _invoke(
      'restore',
      {'operationId': operationId},
      (value) => _receipt(value, 'restored'),
      changesStorage: true,
    );
  }

  /// The native picker may select a persisted operation after a host restart.
  /// The selected directory never crosses the Dart boundary.
  Future<ZcodeReceipt> restoreSelected() => _invoke(
    'restoreSelected',
    {},
    (value) => _receipt(value, 'restored'),
    changesStorage: true,
  );

  Future<ZcodeStatus> requestStop() => _invoke('requestStop', {}, _status);
  Future<ZcodeStatus> reopen() => _invoke('reopen', {}, _status);
}
