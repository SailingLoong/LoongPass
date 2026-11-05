import 'zcode_native.dart';

/// A read-only projection of the native promotion owner, never a claim journal.
/// All timestamps are Unix seconds from the native/server observation.
class ZcodePromotionView {
  final String status;
  final bool canClaim;
  final String? planId, planName, reason;
  final int? startsAt, endsAt, checkedAt;
  String get windowPolicy => 'serverPreview';
  Object? get exactOfferWindow => null;

  const ZcodePromotionView._({required this.status, required this.canClaim,
    this.planId, this.planName, this.reason, this.startsAt, this.endsAt,
    this.checkedAt});
  const ZcodePromotionView.unknown({this.reason})
      : status = 'unknown', canClaim = false, planId = null, planName = null,
        startsAt = null, endsAt = null, checkedAt = null;
}

/// Native owns approved plans, credentials, HTTP, durable pending and dedup.
/// This boundary never retries a method or decides an activity window locally.
class ZcodePromotionsClient {
  final ZcodeCall _call;
  static final _handle = RegExp(r'^[0-9a-f]{64}$');
  static final _unsafe = RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]');
  static const _statuses = {'unknown', 'claimable', 'claimed', 'noClaim',
    'verificationRequired', 'loginExpired', 'resultPending', 'cancelled'};
  static const _fields = {'status', 'canClaim', 'planId', 'planName', 'reason',
    'startsAt', 'endsAt', 'checkedAt', 'windowPolicy', 'exactOfferWindow'};
  static const _businessReasons = {'notDue', 'confirmResult', 'alreadyClaimed',
    'verifyAgain', 'noServerOffer', 'activitySelectionRequired',
    'openOfficialClient', 'loginExpired'};
  ZcodePromotionsClient({required ZcodeCall call}) : _call = call;

  static String? _reason(Object? value) => value == null
      ? null : _businessReasons.contains(value)
          ? value as String : ZcodeNativeFailure.fromCode(value).code;
  static Never _invalid() => throw ZcodeNativeFailure.fromCode('InvalidReply');
  static Map<Object?, Object?> _map(Object? value, Set<String> fields) {
    if (value is! Map || value.keys.any((key) => !fields.contains(key))) {
      _invalid();
    }
    return value;
  }
  static bool _text(Object? value, int length) => value == null ||
      (value is String && value.isNotEmpty && value.length <= length &&
          !_unsafe.hasMatch(value));
  static bool _seconds(Object? value) => value == null ||
      (value is int && value >= 0 && value <= 253402300799);
  static ZcodePromotionView _view(Object? value) {
    final map = _map(value, _fields);
    final status = map['status'], canClaim = map['canClaim'];
    if (!_statuses.contains(status) || canClaim is! bool ||
        (canClaim && status != 'claimable') ||
        (const {'claimable', 'claimed', 'resultPending', 'verificationRequired'}
            .contains(status) && map['planId'] == null) ||
        !_text(map['planId'], 256) || !_text(map['planName'], 256) ||
        !_seconds(map['startsAt']) || !_seconds(map['endsAt']) ||
        !_seconds(map['checkedAt']) ||
        map['windowPolicy'] != 'serverPreview' ||
        map['exactOfferWindow'] != null) {
      _invalid();
    }
    return ZcodePromotionView._(status: status as String, canClaim: canClaim,
      planId: map['planId'] as String?, planName: map['planName'] as String?,
      reason: _reason(map['reason']), startsAt: map['startsAt'] as int?,
      endsAt: map['endsAt'] as int?, checkedAt: map['checkedAt'] as int?);
  }

  Future<Object?> _invoke(String method, Map<String, Object?> args) async {
    try { return await _call(method, Map.unmodifiable(args)); }
    on ZcodeNativeFailure { rethrow; }
    catch (_) { throw ZcodeNativeFailure.fromCode('NativeUnavailable'); }
  }
  void _account(String accountId) {
    if (!_handle.hasMatch(accountId)) {
      throw ZcodeNativeFailure.fromCode('InvalidArguments');
    }
  }

  Future<ZcodeStatus> status() async {
    try {
      final map = _map(await _invoke('promotionStatus', {}), {'available', 'reason'});
      if (map['available'] is! bool) _invalid();
      return ZcodeStatus(map['available'] as bool, _reason(map['reason']));
    } on ZcodeNativeFailure catch (failure) {
      return ZcodeStatus(false, failure.code);
    }
  }

  Future<ZcodePromotionView> preview(String accountId) async {
    _account(accountId);
    return _view(await _invoke('previewPromotions', {'accountId': accountId}));
  }

  Future<ZcodePromotionView> claim(String accountId, {bool automatic = false}) async {
    _account(accountId);
    try {
      return _view(await _invoke('claimPromotions',
        {'accountId': accountId, 'automatic': automatic}));
    } on ZcodeNativeFailure catch (failure) {
      // A lost/malformed reply may follow a completed POST. The native journal
      // owns resolution; no retry, fabricated success or client-side rollback.
      return ZcodePromotionView.unknown(reason: failure.code);
    }
  }
}
