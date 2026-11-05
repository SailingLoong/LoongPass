import 'dart:async';
import 'native_account_gate.dart';
import 'zcode_native.dart';
import 'zcode_promotions.dart';

/// Session-only UI coordination. Native owns all credentials, paths, approved
/// plans, journals and definitive results. Construction performs no I/O.
class ZcodeWorkspace {
  final ZcodeNativeClient native;
  final ZcodePromotionsClient promotions;
  final bool nativeValidated;
  final void Function()? onChanged;
  final _listeners = <void Function()>{};
  final _accounts = <String, ZcodeCapture>{};
  bool _disposed = false, _busy = false, _automatic = false, _ticking = false;
  bool _storageWrite = false;
  int _generation = 0, _automaticRevision = 0;
  Timer? _timer;
  String? _selectedId, _restoreOperation;
  ZcodeCapture? current;
  ZcodeStatus nativeStatus = const ZcodeStatus(false, 'NativeContextUnavailable');
  ZcodeStatus promotionStatus = const ZcodeStatus(false, 'NativeContextUnavailable');
  ZcodePromotionView promotion = const ZcodePromotionView.unknown();
  String? failureCode, lastOutcome;
  bool switchOutcomeUnknown = false;

  ZcodeWorkspace({required this.native, required this.promotions,
    this.nativeValidated = nativeAccountAdaptersValidated, this.onChanged});

  bool get disposed => _disposed;
  bool get busy => _busy;
  bool get automatic => _automatic;
  List<ZcodeCapture> get accounts => List.unmodifiable(_accounts.values);
  ZcodeCapture? get selected => _accounts[_selectedId];
  bool get canUseNative => nativeValidated && !_disposed && !_busy;
  bool get canCapture => canUseNative && (nativeStatus.available ||
      nativeStatus.reason == 'NativeCaptureRequired');
  bool get canSwitch => canCapture && nativeStatus.available &&
      selected != null && current != null &&
      !switchOutcomeUnknown;
  bool get canRestoreLast => canCapture && _restoreOperation != null &&
      !switchOutcomeUnknown;
  bool get canRestoreSelected => canUseNative;
  bool get canPreview => canUseNative && selected != null &&
      (promotionStatus.available || promotionStatus.reason == 'CommitUncertain');
  bool get canClaim => canPreview && promotionStatus.available &&
      promotion.canClaim && promotion.status == 'claimable';
  bool get canEnableAutomatic => canPreview && promotionStatus.available;
  bool get _admitted => nativeValidated && !_disposed && !_busy;

  void addListener(void Function() listener) { if (!_disposed) _listeners.add(listener); }
  void removeListener(void Function() listener) => _listeners.remove(listener);
  void _notify() {
    if (_disposed) return;
    for (final listener in [if (onChanged != null) onChanged!, ..._listeners]) {
      if (_disposed) break;
      try { listener(); } catch (_) { /* UI must not change native outcomes. */ }
    }
  }
  bool _current(int generation) => !_disposed && generation == _generation;
  void _stopAutomatic() {
    _automatic = false;
    _automaticRevision++;
    _timer?.cancel();
    _timer = null;
  }
  void _invalidateContext({bool clearCurrent = false}) {
    _generation++;
    _stopAutomatic();
    promotion = const ZcodePromotionView.unknown();
    failureCode = null;
    lastOutcome = null;
    if (clearCurrent) current = null;
  }

  Future<void> _run(Future<void> Function(int generation) action,
      {bool storageWrite = false}) async {
    if (!_admitted) return;
    final generation = _generation;
    _busy = true;
    _storageWrite = storageWrite;
    failureCode = null;
    _notify();
    try {
      if (!_current(generation)) return;
      await action(generation);
    }
    on ZcodeNativeFailure catch (failure) {
      if (_current(generation)) {
        failureCode = failure.code;
        if (storageWrite && failure.outcomeUnknown) {
          switchOutcomeUnknown = true;
          current = null;
          _restoreOperation = null;
        }
        _stopAutomatic();
      }
    } catch (_) {
      if (_current(generation)) {
        failureCode = 'NativeFailure';
        if (storageWrite) {
          switchOutcomeUnknown = true;
          current = null;
          _restoreOperation = null;
        }
        _stopAutomatic();
      }
    } finally {
      _busy = false;
      _storageWrite = false;
      _notify();
    }
  }

  Future<void> refreshStatus() => _run((generation) async {
    promotion = const ZcodePromotionView.unknown();
    nativeStatus = const ZcodeStatus(false, 'NativeContextUnavailable');
    promotionStatus = const ZcodeStatus(false, 'NativeContextUnavailable');
    final nextNative = await native.status();
    if (!_current(generation)) return;
    final nextPromotion = await promotions.status();
    if (!_current(generation)) return;
    nativeStatus = nextNative;
    promotionStatus = nextPromotion;
    // A context-first gate may report active writers for file switching while
    // the separately authenticated promotion owner can still use network APIs.
    // Current-file capture is likewise independent of a saved promotion account.
    final contextKnown = nextNative.available ||
        const {'WritersActive', 'NativeCaptureRequired'}.contains(nextNative.reason);
    if (!contextKnown || !nextPromotion.available) {
      _stopAutomatic();
      promotion = const ZcodePromotionView.unknown();
    }
  });

  Future<void> requestStop() async {
    if (!canUseNative) return;
    _invalidateContext(clearCurrent: true);
    await _run((generation) async {
      final result = await native.requestStop();
      if (_current(generation)) nativeStatus = result;
    });
  }

  Future<void> reopen() async {
    if (!canUseNative) return;
    _invalidateContext(clearCurrent: true);
    await _run((generation) async {
      final result = await native.reopen();
      if (_current(generation)) nativeStatus = result;
    });
  }

  Future<void> captureCurrent() async {
    if (!canCapture) return;
    _invalidateContext(clearCurrent: true);
    // A failed recapture must not leave the old revision or readiness usable.
    // The native owner still validates every explicit capture attempt.
    nativeStatus = const ZcodeStatus(false, 'NativeCaptureRequired');
    await _run((generation) async {
      final captured = await native.captureCurrent();
      if (!_current(generation)) return;
      _accounts[captured.accountId] = captured;
      current = captured;
      _selectedId ??= captured.accountId;
      final status = await native.status();
      if (_current(generation)) nativeStatus = status;
    });
  }

  Future<void> captureSelected() async {
    if (!canCapture) return;
    _invalidateContext();
    await _run((generation) async {
      final captured = await native.captureSelected();
      if (!_current(generation)) return;
      _accounts[captured.accountId] = captured;
      _selectedId = captured.accountId;
    });
  }

  void selectAccount(String? accountId) {
    if (_disposed || _storageWrite || accountId == _selectedId ||
        (accountId != null && !_accounts.containsKey(accountId))) return;
    _invalidateContext();
    _selectedId = accountId;
    _notify();
  }

  Future<void> switchSelected() async {
    if (!canSwitch) return;
    final account = selected!, revision = current!.revision;
    _invalidateContext();
    await _run((generation) async {
      final result = await native.switchAccount(accountId: account.accountId,
        expectedRevision: revision);
      if (!_current(generation)) return;
      lastOutcome = result.outcome;
      _restoreOperation = result.operationId;
      current = null;
    }, storageWrite: true);
  }

  Future<void> restoreLast() async {
    if (!canRestoreLast) return;
    final operationId = _restoreOperation!;
    _invalidateContext();
    await _run((generation) async {
      final result = await native.restore(operationId: operationId);
      if (!_current(generation)) return;
      lastOutcome = result.outcome;
      current = null;
      _restoreOperation = null;
    }, storageWrite: true);
  }

  /// Explicit native picker supports recovery after restart. The native owner
  /// revalidates the selected journal and refuses stale or unsafe restoration.
  Future<void> restoreSelected() async {
    if (!canRestoreSelected) return;
    _invalidateContext();
    await _run((generation) async {
      final result = await native.restoreSelected();
      if (!_current(generation)) return;
      lastOutcome = result.outcome;
      current = null;
      _restoreOperation = null;
      switchOutcomeUnknown = false;
    }, storageWrite: true);
  }

  Future<void> previewPromotions() async {
    if (!canPreview) return;
    final accountId = selected!.accountId;
    await _run((generation) async {
      promotion = const ZcodePromotionView.unknown();
      final result = await promotions.preview(accountId);
      if (_current(generation)) promotion = result;
    });
  }

  void _claimResult(ZcodePromotionView result) {
    promotion = result;
    if (const {'unknown', 'resultPending', 'verificationRequired', 'loginExpired',
      'cancelled'}.contains(result.status)) _stopAutomatic();
  }

  Future<void> claimPromotions() async {
    if (!canClaim) return;
    final accountId = selected!.accountId;
    await _run((generation) async {
      // Retire the preview before dispatch, so it cannot be reused after a lost
      // response. Rechecking remains an explicit read delegated to native.
      promotion = const ZcodePromotionView.unknown();
      final result = await promotions.claim(accountId);
      if (_current(generation)) _claimResult(result);
    });
  }

  void setAutomatic(bool enabled) {
    if (_disposed) return;
    if (!enabled) { _stopAutomatic(); _notify(); return; }
    if (!canEnableAutomatic || _automatic) return;
    _automatic = true;
    _automaticRevision++;
    // Existing in-process Timer/automaticTick pattern; session only. There is
    // no immediate/startup claim, OS schedule, local calendar gate or storage.
    _timer = Timer.periodic(const Duration(minutes: 10), (_) {
      if (!_disposed) unawaited(automaticTick());
    });
    _notify();
  }

  Future<void> automaticTick() async {
    if (!_automatic || _ticking || !canEnableAutomatic) return;
    _ticking = true;
    final accountId = selected!.accountId;
    final consent = _automaticRevision;
    try {
      await _run((generation) async {
        if (!_automatic || consent != _automaticRevision) return;
        promotion = const ZcodePromotionView.unknown();
        final preview = await promotions.preview(accountId);
        if (!_current(generation) || !_automatic ||
            consent != _automaticRevision || selected?.accountId != accountId) return;
        promotion = preview;
        if (!preview.canClaim || preview.status != 'claimable') {
          if (const {'unknown', 'resultPending', 'verificationRequired',
            'loginExpired', 'cancelled'}.contains(preview.status)) _stopAutomatic();
          return;
        }
        promotion = const ZcodePromotionView.unknown();
        final result = await promotions.claim(accountId, automatic: true);
        if (_current(generation)) _claimResult(result);
      });
    } finally { _ticking = false; }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _stopAutomatic();
    _listeners.clear();
    _accounts.clear();
    _selectedId = null;
    current = null;
  }
}
