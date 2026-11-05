// Account roster. Flows own authentication and claims; the injected store owns
// saved authorization, and the independent journal owns check-in attempts.
import 'dart:async';
import 'dart:convert';

import 'workbuddy_account_flow.dart';
import 'workbuddy_balance.dart';
import 'workbuddy_claim.dart';
import 'workbuddy_vault.dart';
import 'workbuddy_desktop_session.dart';

class WorkBuddyAccountSession {
  final String id;
  final WorkBuddyAccountFlow _flow;
  bool _verified = false, _saving = false;
  bool _followingAuthorization = false;
  Timer? _authorizationTimer;
  WorkBuddyVault? _vault;
  String? _vaultKey;
  WorkBuddyAccountSession._(this.id, this._flow);
  String? get uid => _verified ? _flow.uid : null;
  String? get domain => _verified ? _flow.domain : null;
  bool get loginPending => _flow.loginPending;
  bool get busy => _saving || _flow.busy;
  bool get canClaim => _verified && _flow.canClaim;
  bool get claimOwnerAvailable => _flow.claimOwnerAvailable;
  String? get message => _flow.message;
  WorkBuddyState? get status => _flow.status;
  WorkBuddyResult? get result => _flow.result;
  CreditSummary? get credits => _flow.credits;
  double? get totalRemaining => _flow.totalRemaining;
  @override
  String toString() => 'WorkBuddyAccountSession(redacted)';
}

class WorkBuddyAccounts {
  /// Explicit factory only: production callers use the existing guarded native
  /// factory; synthetic tests inject existing flows with fake exchanges/stores.
  final FutureOr<WorkBuddyAccountFlow> Function() create;
  final void Function()? onChanged;
  final void Function(String id)? onAccountReady;
  final _sessions = <String, WorkBuddyAccountSession>{};
  final _identities = <String, String>{};
  bool _closed = false, _claiming = false, _restoring = false;
  int _sequence = 0, _epoch = 0;
  String? _selected, _message;
  WorkBuddyAccounts({
    required this.create,
    this.onChanged,
    this.onAccountReady,
  });
  void _ready(String id) {
    try {
      onAccountReady?.call(id);
    } catch (_) {
      /* Admission remains valid if a consumer fails. */
    }
  }

  List<WorkBuddyAccountSession> get sessions =>
      List.unmodifiable(_sessions.values);
  List<WorkBuddyAccountSession> get accounts =>
      List.unmodifiable(_sessions.values.where((s) => s.uid != null));
  List<WorkBuddyAccountSession> get pending =>
      List.unmodifiable(_sessions.values.where((s) => s.loginPending));
  WorkBuddyAccountSession? get selected => _sessions[_selected];
  String? get message => _message;
  bool get claimBusy => _claiming;
  bool _owns(WorkBuddyAccountSession slot) =>
      !_closed && identical(_sessions[slot.id], slot);
  String _key(WorkBuddyAccountSession slot) =>
      jsonEncode([slot._flow.domain, slot._flow.uid]);

  Future<int> restoreSaved(
    WorkBuddyVault vault,
    Future<List<String>> Function() savedKeys,
  ) async {
    if (_closed || _restoring) return 0;
    _restoring = true;
    try {
      final keys = await savedKeys();
      if (_closed) return 0;
      if (keys.isEmpty) {
        _message = '尚无可恢复的账号。';
        return 0;
      }
      var restored = 0, failed = 0;
      for (final key in keys) {
        if (_closed) break;
        if (_sessions.values.any(
          (s) => identical(s._vault, vault) && s._vaultKey == key,
        ))
          continue;
        if (await restore(vault, key) != null) {
          restored++;
        } else {
          failed++;
        }
      }
      if (!_closed)
        _message = failed == 0 ? null : '$failed 个保存账号未能通过身份核验；其余账号可继续使用。';
      return restored;
    } catch (_) {
      if (!_closed) _message = '保存记录未能读取；已有账号保持不变。';
      return 0;
    } finally {
      _restoring = false;
    }
  }

  Future<String?> restore(WorkBuddyVault vault, String key) async {
    if (_closed ||
        _sessions.values.any(
          (s) => identical(s._vault, vault) && s._vaultKey == key,
        ))
      return null;
    final epoch = _epoch;
    WorkBuddyAccountSession? slot;
    try {
      final flow = await create();
      if (_sessions.values.any((s) => identical(s._flow, flow)) ||
          flow.uid != null ||
          flow.loginPending ||
          flow.busy)
        return null;
      if (_closed || epoch != _epoch) {
        flow.close();
        return null;
      }
      slot = WorkBuddyAccountSession._('session-${++_sequence}', flow);
      slot._vault = vault;
      slot._vaultKey = key;
      _sessions[slot.id] = slot;
      final owner = slot;
      final lease = await vault.restore(
        key,
        verify: (credential, admitted) => flow.restoreCredential(
          credential,
          admission: () => _owns(owner) && admitted(),
        ),
      );
      if (!_owns(owner)) return null;
      if (lease == null || !flow.attachRestoredLease(lease)) {
        _retire(owner);
        return null;
      }
      final identity = _key(owner), existing = _identities[_key(owner)];
      if (existing != null && _sessions[existing]?.uid != null) {
        _retire(owner);
        _selected = existing;
        return null;
      }
      owner._verified = true;
      _identities[identity] = owner.id;
      _selected = owner.id;
      _message = null;
      _ready(owner.id);
      return owner.id;
    } catch (_) {
      if (slot != null && _owns(slot)) _retire(slot);
      return null;
    }
  }

  Future<void> revokeStored(String id) async {
    final slot = _sessions[id];
    if (slot == null || !_owns(slot)) return;
    final vault = slot._vault, key = slot._vaultKey;
    _retire(slot); // Synchronously retire sends before any durable await.
    if (vault != null && key != null) await vault.revoke(key);
  }

  Future<({String sessionId, Uri url})?> beginAuthorization() async {
    if (_closed) return null;
    final epoch = _epoch;
    WorkBuddyAccountSession? slot;
    try {
      final flow = await create();
      // A bad factory must not reuse or close an existing account's owner.
      if (_sessions.values.any((s) => identical(s._flow, flow)) ||
          flow.uid != null ||
          flow.loginPending ||
          flow.busy) {
        if (!_closed) _message = '授权工厂返回了已有会话，未发起新的授权。';
        return null;
      }
      if (_closed || epoch != _epoch) {
        flow.close();
        return null;
      }
      slot = WorkBuddyAccountSession._('session-${++_sequence}', flow);
      _sessions[slot.id] = slot;
      final url = await flow.begin();
      if (!_owns(slot)) return null;
      if (url == null) {
        _retire(slot);
        _message = '授权未开始；已有账号与领取记录未改变。';
        return null;
      }
      _message = null;
      return (sessionId: slot.id, url: url);
    } catch (_) {
      if (slot != null && _owns(slot)) _retire(slot);
      if (!_closed) _message = '授权会话未能创建；已有账号与领取记录未改变。';
      return null;
    }
  }

  /// Follow the current grant after its official authorization page opens.
  /// This owner controls polling, persistence and cancellation together.
  void followAuthorization(String id, {WorkBuddyVault? vault}) {
    final slot = _sessions[id];
    if (slot == null ||
        !_owns(slot) ||
        !slot.loginPending ||
        slot._followingAuthorization)
      return;
    slot._followingAuthorization = true;
    Future<void> check() async {
      slot._authorizationTimer = null;
      if (!_owns(slot) || slot._verified || !slot.loginPending) return;
      try {
        if (vault == null) {
          await poll(id);
        } else {
          await pollAndSave(id, vault);
        }
      } catch (_) {
        if (_owns(slot)) _message = '授权结果或账号保存未能确认，请检查本次授权记录。';
      } finally {
        if (!_closed) {
          try {
            onChanged?.call();
          } catch (_) {
            /* Rendering does not own authorization. */
          }
        }
        if (_owns(slot) && !slot._verified && slot.loginPending) {
          slot._authorizationTimer = Timer(
            const Duration(seconds: 2),
            () => unawaited(check()),
          );
        } else {
          slot._followingAuthorization = false;
        }
      }
    }

    unawaited(check());
  }

  /// Same existing authorization flow; persistence is explicit and injected.
  /// Only admit after profile identity and safe save both succeed.
  Future<String?> pollAndSave(String id, WorkBuddyVault vault) async {
    final slot = _sessions[id];
    if (slot == null || !_owns(slot) || slot._verified || slot._saving)
      return null;
    slot._saving = true;
    String? savedKey;
    try {
      await slot._flow.poll();
      if (!_owns(slot)) return null;
      final uid = slot._flow.uid, domain = slot._flow.domain;
      if (uid == null || domain == null) {
        if (!slot._flow.loginPending && !slot._flow.busy) {
          _retire(slot);
          _message = '授权未完成或已过期，请重新添加。';
        }
        return null;
      }
      final existing = _identities[_key(slot)];
      if (existing != null && existing != id) {
        final previous = _sessions[existing];
        if (previous != null && previous._flow.authorized) {
          _retire(slot);
          _selected = existing;
          _message = '该账号已保存，已选中现有账号。';
          return null;
        }
        if (previous != null) _retire(previous);
      }
      final key = WorkBuddyVault.accountKey(domain, uid);
      if (!await slot._flow.saveVerified(
        vault,
        key,
        admission: () => _owns(slot),
      )) {
        if (_owns(slot)) _retire(slot);
        return null;
      }
      savedKey = key;
      final bound = await slot._flow.bindSaved(
        vault,
        key,
        admission: () => _owns(slot),
      );
      if (!bound || !_owns(slot)) {
        await vault.revoke(key);
        savedKey = null;
        if (_owns(slot)) _retire(slot);
        return null;
      }
      slot._vault = vault;
      slot._vaultKey = key;
      slot._verified = true;
      _identities[_key(slot)] = id;
      _selected = id;
      _message = null;
      return id;
    } catch (_) {
      if (_owns(slot)) _retire(slot);
      _message = '账号保存或清理结果未核实；账号未开放，不能据此确认已撤销保存。';
      if (savedKey != null) await vault.revoke(savedKey);
      return null;
    } finally {
      slot._saving = false;
      if (_owns(slot) && slot._verified) _ready(id);
    }
  }

  Future<void> poll(String id) async {
    final slot = _sessions[id];
    if (slot == null || !_owns(slot) || slot.uid != null || slot._saving)
      return;
    await slot._flow.poll();
    if (!_owns(slot)) return;
    if (slot._flow.uid == null) {
      if (!slot.loginPending && !slot.busy) {
        _retire(slot);
        _message = '该授权未完成或已过期，已有账号未改变。';
      }
      return;
    }
    final key = _key(slot), existing = _identities[_key(slot)];
    if (existing != null &&
        existing != id &&
        _sessions[existing]?.uid != null) {
      _retire(slot);
      _selected = existing;
      _message = '该账号已在本次会话中；保留原账号状态，未覆盖凭据或领取记录。';
      return;
    }
    slot._verified = true;
    _identities[key] = id;
    _selected = id;
    _message = null;
  }

  void cancelAuthorization(String id) {
    final slot = _sessions[id];
    if (slot == null || !_owns(slot) || slot.uid != null) return;
    _retire(slot);
    _message = '仅取消了该授权会话；其他账号未改变。';
  }

  void select(String id) {
    final slot = _sessions[id];
    if (slot == null || !_owns(slot) || slot.uid == null) return;
    _selected = id;
    _message = null;
  }

  Future<void> refreshStatus(String id, {bool Function()? admission}) async {
    final slot = _sessions[id];
    if (slot == null || !_owns(slot) || slot.uid == null) return;
    await slot._flow.refreshStatus(
      admission: () => _owns(slot) && (admission?.call() ?? true),
    );
  }

  Future<void> refreshBalance(String id) async {
    final slot = _sessions[id];
    if (slot == null || !_owns(slot) || slot.uid == null) return;
    await slot._flow.refreshBalance();
  }

  Future<String> activateDesktop(
    String id,
    Future<String> Function(WorkBuddyDesktopSession) activate,
  ) async {
    final slot = _sessions[id];
    if (slot == null ||
        !_owns(slot) ||
        slot.uid == null ||
        _claiming ||
        slot.busy) {
      return 'unavailable';
    }
    _claiming = true;
    try {
      return await slot._flow.activateDesktop(activate);
    } finally {
      _claiming = false;
    }
  }

  Future<void> claim(String id, {bool Function()? admission}) async {
    final slot = _sessions[id];
    if (slot == null ||
        !_owns(slot) ||
        slot.uid == null ||
        _claiming ||
        !slot.canClaim)
      return;
    // One owning isolate and one journal mutation at a time. A concurrent user
    // request is ignored, never queued to send later without a fresh action.
    _claiming = true;
    try {
      await slot._flow.claim(
        admission: () => _owns(slot) && (admission?.call() ?? true),
      );
    } finally {
      _claiming = false;
    }
  }

  void remove(String id) {
    final slot = _sessions[id];
    if (slot == null || !_owns(slot)) return;
    _retire(slot);
    _message = '已移除本次内存账号；领取记录保留，未知结果不会自动补发。';
  }

  void _retire(WorkBuddyAccountSession slot) {
    slot._authorizationTimer?.cancel();
    slot._authorizationTimer = null;
    _sessions.remove(slot.id);
    _identities.removeWhere((_, id) => id == slot.id);
    slot._flow.close();
    if (_selected == slot.id)
      _selected = accounts.isEmpty ? null : accounts.first.id;
  }

  /// Retire all network/authorization gates and memory only. Pending and settled
  /// receipts survive through the unchanged store and require reauthorization.
  void close() {
    if (_closed) return;
    _closed = true;
    _epoch++;
    for (final slot in _sessions.values) {
      slot._authorizationTimer?.cancel();
      slot._flow.close();
    }
    _sessions.clear();
    _identities.clear();
    _selected = null;
    _message = null;
  }
}
