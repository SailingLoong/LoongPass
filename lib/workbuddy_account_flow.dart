import 'claim_receipt.dart';
import 'dart:math';

import 'workbuddy_api.dart';
import 'workbuddy_desktop_session.dart';
import 'workbuddy_balance.dart';
import 'workbuddy_claim.dart';
import 'workbuddy_vault.dart';

/// One in-memory authorized account, with an optional non-secret attempt journal.
/// The default memory factory owns its generation and retirement gate.
/// All claims use the reviewed core; this class never calls claimOnce directly.
class WorkBuddyAccountFlow {
  factory WorkBuddyAccountFlow.inMemory({
    WorkBuddyExchange? exchange,
    DateTime Function()? now,
    WorkBuddyAttemptStore? store,
    bool identityValidationOnly = false,
  }) {
    if (exchange == null) {
      if (identityValidationOnly) {
        requireWorkBuddyIdentityAccess();
      } else {
        requireWorkBuddyProductionAccess();
      }
    }
    final random = Random.secure();
    final generation = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    late final WorkBuddyAccountFlow flow;
    flow = WorkBuddyAccountFlow(
      exchange:
          exchange ??
          (identityValidationOnly
              ? WorkBuddyHttps.identityValidation()
              : WorkBuddyHttps()),
      identityValidationOnly: identityValidationOnly,
      ownerGeneration: 'memory-$generation',
      isOwnerCurrent: () => !flow._closed,
      now: now,
      store: store,
    );
    return flow;
  }
  WorkBuddyAccountFlow({
    required WorkBuddyExchange exchange,
    required this.ownerGeneration,
    required this.isOwnerCurrent,
    this.store,
    this.readCompleteBalance,
    bool identityValidationOnly = false,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now,
       identityValidationOnly =
           identityValidationOnly ||
           exchange is WorkBuddyIdentityExchange ||
           (exchange is WorkBuddyHttps && exchange.identityValidationOnly) {
    if (exchange is WorkBuddyHttps) exchange.requireAccess();
    if (this.identityValidationOnly &&
        (store != null || readCompleteBalance != null))
      throw const WorkBuddyFailure('IdentityStorageUnavailable');
    if (ownerGeneration.trim().isEmpty) {
      throw const WorkBuddyFailure('MissingOwnerGeneration');
    }
    _exchange =
        this.identityValidationOnly && exchange is! WorkBuddyIdentityExchange
        ? WorkBuddyIdentityExchange(exchange)
        : exchange;
    _api = WorkBuddyApi(
      _exchange,
      isCurrent: () => _networkAdmitted,
      now: this.now,
    );
  }

  /// Must be unique to the caller's real credential-owner lifetime, not a fixed
  /// production constant. Old unresolved attempts remain in the same store.
  final String ownerGeneration;
  final bool identityValidationOnly;
  final bool Function() isOwnerCurrent;
  final WorkBuddyAttemptStore? store;

  /// The owner must also enforce flow.isCurrent(subject) at its own network
  /// send boundaries, including after asynchronous setup. Missing data is null,
  /// never a partial total. The API bridge rechecks identity after the await.
  final WorkBuddyBalanceReader? readCompleteBalance;
  final DateTime Function() now;
  late WorkBuddyApi _api;
  late final WorkBuddyExchange _exchange;
  WorkBuddyVaultLease? _vaultLease;
  bool Function()? _restoreAdmission;
  bool _restorePending = false;
  WorkBuddyVaultCredential? _restoredCredential;
  WorkBuddyAccount? _account;
  WorkBuddySubject? _subject;
  WorkBuddyClaimCore? _core;
  WorkBuddyBalanceReader? _balanceReader;
  double? _totalRemaining;
  CreditSummary? _credits;
  CreditSummary? get credits => _credits;
  bool _closed = false, _busy = false, _pending = false;
  int _epoch = 0, _authorization = 0;
  String? _message;
  WorkBuddyState? _status;
  WorkBuddyResult? _result;
  ClaimReceipt? _latestClaim;
  ClaimReceipt? get latestClaim => _latestClaim;

  bool Function()? _operationAdmission;
  bool get _live {
    if (_closed || !isOwnerCurrent()) return false;
    try {
      return (_restoreAdmission?.call() ?? true) &&
          (_vaultLease?.current ?? true);
    } catch (_) {
      return false;
    }
  }

  bool get _networkAdmitted {
    if (!_live) return false;
    try {
      return _operationAdmission?.call() ?? true;
    } catch (_) {
      return false;
    }
  }

  bool _same(int epoch) => !_closed && epoch == _epoch;
  bool get busy => _busy;
  bool get loginPending => _live && _pending;
  bool get canClaim =>
      !identityValidationOnly &&
      _live &&
      !_restorePending &&
      !_busy &&
      !_pending &&
      _core != null &&
      _result?.state != WorkBuddyState.unconfirmed &&
      _result?.state != WorkBuddyState.needsVerification &&
      _status != WorkBuddyState.needsVerification;
  bool get claimOwnerAvailable =>
      !identityValidationOnly && store != null && _balanceReader != null;
  bool isCurrent(WorkBuddySubject subject) =>
      _networkAdmitted && _subject?.matches(subject) == true;
  bool get authorized =>
      _live &&
      _account != null &&
      _status != WorkBuddyState.needsVerification &&
      _result?.state != WorkBuddyState.needsVerification;
  String? get uid => !_closed ? _account?.uid : null;
  String? get domain => !_closed ? _account?.domain : null;
  String? get message => !_closed && _account != null && !authorized
      ? '授权已不可用，请重新授权此账号。'
      : _message;
  WorkBuddyState? get status => _status;
  WorkBuddyResult? get result => _result;
  double? get totalRemaining => _totalRemaining;
  Future<String> activateDesktop(
    Future<String> Function(WorkBuddyDesktopSession) activate,
  ) async {
    final account = _account;
    if (identityValidationOnly ||
        !authorized ||
        _busy ||
        _restorePending ||
        account == null) {
      return 'unavailable';
    }
    final epoch = _epoch;
    _busy = true;
    try {
      final session = await _api.desktopSession(
        account,
        gate: () => _same(epoch) && _live,
      );
      if (!_same(epoch) || !_live) return 'unavailable';
      final result = await activate(session);
      return _same(epoch) && _live ? result : 'unknown';
    } finally {
      if (_same(epoch)) _busy = false;
    }
  }

  Future<void> refreshBalance() async {
    if (identityValidationOnly) return;
    final subject = _subject, reader = _balanceReader;
    if (!_live || _busy || subject == null || reader == null) return;
    final epoch = _epoch;
    _busy = true;
    _totalRemaining = null;
    _credits = null;
    try {
      final balance = await reader(subject);
      if (!_same(epoch) || !isCurrent(subject)) return;
      if (!balance.subject.matches(subject))
        throw const WorkBuddyFailure('IdentityMismatch');
      final total = balance.totalRemaining;
      _totalRemaining = total != null && total.isFinite && total >= 0
          ? total
          : null;
      _message = _totalRemaining == null ? '完整额度尚未核实，不使用部分余额判断到账。' : null;
    } catch (_) {
      if (_same(epoch)) _message = '未能核实完整额度；没有发送或补发签到请求。';
    } finally {
      if (_same(epoch)) _busy = false;
    }
  }

  /// Only a fresh flow may restore. Admission remains tied to the vault
  /// lifetime; roster deduplication still runs before any account is visible.
  Future<bool> restoreCredential(
    WorkBuddyVaultCredential c, {
    required bool Function() admission,
  }) async {
    if (identityValidationOnly) return false;
    if (!_live || _busy || _pending || _account != null || !admission())
      return false;
    final epoch = ++_epoch;
    _busy = true;
    _restorePending = true;
    _restoreAdmission = admission;
    try {
      final account = WorkBuddyAccount(
        c.domain,
        c.uid,
        c.accessToken,
        expiresAt: c.expiresAt,
      );
      _api = WorkBuddyApi(
        _exchange,
        isCurrent: () => _networkAdmitted,
        now: now,
        endpointHost: c.endpoint,
        prepareAdmission: () async =>
            _vaultLease == null ? _live : await _vaultLease!.checkCurrent(),
      );
      await _api.verifyStoredAccount(
        account,
        gate: () => _same(epoch) && _live,
      );
      if (!_same(epoch) || !_live) return false;
      _restoredCredential = c;
      _bind(account);
      await _loadLatestClaim();
      return true;
    } catch (_) {
      return false;
    } finally {
      if (_same(epoch)) _busy = false;
    }
  }

  bool attachRestoredLease(WorkBuddyVaultLease lease) {
    if (identityValidationOnly) return false;
    final verified = _restoredCredential, c = lease.credential;
    if (!_live ||
        !lease.current ||
        verified == null ||
        verified.domain != c.domain ||
        verified.uid != c.uid ||
        verified.endpoint != c.endpoint ||
        verified.accessToken != c.accessToken ||
        verified.refreshToken != c.refreshToken ||
        verified.expiresAt != c.expiresAt ||
        !_restorePending)
      return false;
    _vaultLease = lease;
    _api.prepareAdmission = () => lease.checkCurrent();
    _restorePending = false;
    _message = '身份已核实，授权已保存在本机。';
    return true;
  }

  Future<bool> bindSaved(
    WorkBuddyVault vault,
    String key, {
    required bool Function() admission,
  }) async {
    if (identityValidationOnly) return false;
    final account = _account;
    if (!_live || _busy || account == null || !admission()) return false;
    _busy = true;
    _restorePending = true;
    try {
      final lease = await vault.restore(
        key,
        verify: (c, admitted) async {
          if (!_live ||
              !admission() ||
              !admitted() ||
              !_api.matchesStoredAccount(account, c))
            return false;
          _restoredCredential = c;
          _restoreAdmission = () => admission() && admitted();
          return true;
        },
      );
      return lease != null && attachRestoredLease(lease);
    } finally {
      if (!_closed) _busy = false;
    }
  }

  Future<bool> saveVerified(
    WorkBuddyVault vault,
    String key, {
    required bool Function() admission,
  }) async {
    if (identityValidationOnly) return false;
    final account = _account;
    if (!_live ||
        _busy ||
        _pending ||
        _restorePending ||
        _vaultLease != null ||
        account == null)
      return false;
    final epoch = _epoch;
    _busy = true;
    try {
      return await _api.saveVerifiedAccount(
        account,
        vault,
        key,
        gate: () => _same(epoch) && _live && admission(),
      );
    } finally {
      if (_same(epoch)) _busy = false;
    }
  }

  Future<({WorkBuddySubject subject, double? totalRemaining})> _readBalance(
    WorkBuddyAccount account,
    WorkBuddySubject requested,
  ) async {
    final credits = await _api.creditDetails(
      account,
      requested,
      gate: () => isCurrent(requested),
    );
    if (isCurrent(requested)) _credits = credits;
    return (subject: requested, totalRemaining: credits?.totalRemaining);
  }

  void _bind(WorkBuddyAccount account) {
    _authorization++;
    final subject = WorkBuddySubject(
      account.domain,
      account.uid,
      '$ownerGeneration:$_authorization',
    );
    _account = account;
    _subject = subject;
    _pending = false;
    final balance = _balanceReader =
        readCompleteBalance ?? (requested) => _readBalance(account, requested);
    final attempts = store;
    if (attempts != null)
      _core = WorkBuddyClaimCore(
        attempts,
        WorkBuddyApiTransport(
          _api,
          account,
          subject,
          readCompleteBalance: balance,
        ),
        now,
        isCurrent: isCurrent,
      );
  }

  Future<Uri?> begin() async {
    if (!_live || _busy || _pending || _account != null) return null;
    final epoch = ++_epoch;
    _authorization++;
    _busy = true;
    _pending = true;
    _message = null;
    try {
      final uri = await _api.begin();
      if (!_same(epoch) || !_live) return null;
      _message = '请在官方网页完成授权，再检查授权结果。';
      return uri;
    } catch (_) {
      if (_same(epoch)) {
        _pending = false;
        _api.cancel();
        _message = '授权未开始或已过期，未保存账号。';
      }
      return null;
    } finally {
      if (_same(epoch)) _busy = false;
    }
  }

  Future<void> poll() async {
    if (!_live || _busy || !_pending) return;
    final epoch = _epoch;
    _busy = true;
    try {
      final account = await _api.poll();
      if (!_same(epoch) || !_live) return;
      if (account == null) {
        _message = '尚未完成官方授权。';
        return;
      }
      final subject = WorkBuddySubject(
        account.domain,
        account.uid,
        '$ownerGeneration:$_authorization',
      );
      _account = account;
      _subject = subject;
      _pending = false;
      final balance = _balanceReader =
          readCompleteBalance ??
          (requested) => _readBalance(account, requested);
      final attempts = store;
      if (attempts != null) {
        _core = WorkBuddyClaimCore(
          attempts,
          WorkBuddyApiTransport(
            _api,
            account,
            subject,
            readCompleteBalance: balance,
          ),
          now,
          isCurrent: isCurrent,
        );
      }
      await _loadLatestClaim();
      _message = '已核实授权账号，仅保留在本次内存中；未签到，未切换桌面账号。';
    } catch (error) {
      if (_same(epoch)) {
        if (error is WorkBuddyApiFailure && error.code == 'OutcomeUnknown') {
          _message = '暂未能读取官网授权结果或账号资料，将继续核验本次授权。';
          return;
        }
        _pending = false;
        _api.cancel();
        _message = '授权未完成或已过期，未保存账号；请重新发起授权。';
      }
    } finally {
      if (_same(epoch)) _busy = false;
    }
  }

  void cancelLogin() {
    if (_closed || _account != null) return;
    _epoch++;
    _api.cancel();
    _pending = false;
    _busy = false;
    _message = '本次内存授权已取消，未保存账号。';
  }

  /// This reads activity eligibility only. It cannot resolve a lost receipt,
  /// clear a persisted intent or turn a displayed unknown result into success.
  Future<void> refreshStatus({bool Function()? admission}) async {
    if (identityValidationOnly) return;
    final account = _account;
    if (!_live || _busy || account == null) return;
    if (admission != null) {
      try {
        if (!admission()) return;
      } catch (_) {
        return;
      }
    }
    final epoch = _epoch;
    _operationAdmission = admission;
    _busy = true;
    try {
      final response = await _api.status(account);
      if (_same(epoch) && _live) _status = WorkBuddyProtocol.status(response);
    } catch (error) {
      if (_same(epoch)) {
        _status =
            error is WorkBuddyApiFailure &&
                [
                  'NeedsVerification',
                  'ExpiredAuthorization',
                ].contains(error.code)
            ? WorkBuddyState.needsVerification
            : WorkBuddyState.unconfirmed;
        _message = '未能核实当前活动状态；没有补发签到请求。';
      }
    } finally {
      _operationAdmission = null;
      if (_same(epoch)) _busy = false;
    }
  }

  Future<void> _loadLatestClaim() async {
    final subject = _subject, attempts = store;
    if (subject == null || attempts == null || identityValidationOnly) return;
    try {
      final row = attempts is WorkBuddyAttemptHistory
          ? await (attempts as WorkBuddyAttemptHistory).latestSuccessful(
              subject.key,
            )
          : await attempts.read(subject.key);
      if (!_closed &&
          _subject == subject &&
          row?.settled == WorkBuddyState.claimed) {
        _latestClaim = ClaimReceipt(amount: row!.credited, day: row.day);
      }
    } catch (_) {
      /* Receipt history is optional; never replay a claim to fill it. */
    }
  }

  Future<void> claim({bool Function()? admission}) async {
    final core = _core, subject = _subject;
    if (!canClaim || core == null || subject == null) return;
    if (admission != null) {
      try {
        if (!admission()) return;
      } catch (_) {
        return;
      }
    }
    final epoch = _epoch;
    _operationAdmission = admission;
    _busy = true;
    _message = null;
    try {
      final result = await core.claim(subject);
      await _loadLatestClaim();
      if (_same(epoch)) {
        _result = _live
            ? result
            : const WorkBuddyResult(WorkBuddyState.unconfirmed);
        if (_result!.state != WorkBuddyState.unconfirmed)
          _status = _result!.state;
      }
    } catch (_) {
      if (_same(epoch))
        _result = const WorkBuddyResult(WorkBuddyState.unconfirmed);
    } finally {
      _operationAdmission = null;
      if (_same(epoch)) _busy = false;
    }
  }

  /// Retire memory and all send gates. Never delete or reset persisted attempts.
  void close() {
    _closed = true;
    _epoch++;
    _api.cancel();
    _vaultLease = null;
    _restoreAdmission = null;
    _restoredCredential = null;
    _account = null;
    _subject = null;
    _core = null;
    _balanceReader = null;
    _totalRemaining = null;
    _credits = null;
    _pending = false;
    _busy = false;
    _status = null;
    _result = null;
    _latestClaim = null;
    _message = null;
  }
}
