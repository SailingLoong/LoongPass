import 'dart:convert';

import 'credit_expiry_history.dart';
import 'plugin_accounts.dart';
import 'zcode_api.dart';
import 'zcode_rewards.dart';

/// Owns only ZCode activity transactions. The native host owns credentials and
/// paid-plan usage.
class PluginZcodeRewards {
  PluginZcodeRewards(
    this.accounts, {
    ZcodeApi? api,
    int Function()? now,
    this.contextFor,
  }) : api = api ?? ZcodeApi(ZcodeHttp()),
       now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final PluginAccounts accounts;
  final ZcodeApi api;
  final int Function() now;
  final Future<Map<String, String>> Function(
    PluginAccount,
    Map<String, dynamic>,
  )?
  contextFor;
  static final _writers = <String>{};
  bool _closed = false;

  Future<void> refresh(String key) => _exclusive(key, submit: false);

  /// Captures verified binding metadata without querying or claiming rewards.
  /// Used before and after an explicit native rebind so both devices survive.
  Future<void> captureBinding(String key) =>
      _exclusive(key, submit: false, bindingOnly: true);
  Future<void> claim(
    String key, {
    Future<String?> Function(ZcodeCaptchaConfig)? verify,
  }) => _exclusive(key, submit: true, verify: verify);
  Future<void> close() async {
    _closed = true;
  }

  PluginAccount _account(String key) {
    if (_closed) throw const ZcodeFailure('closed');
    for (final a in accounts.accounts) {
      if (a.key == key &&
          a.active &&
          a.provider == 'zcode' &&
          zcodeText(a.uid) &&
          {'bigmodel', 'zai'}.contains(a.realm))
        return a;
    }
    throw const ZcodeFailure('account_missing');
  }

  bool _current(PluginAccount captured) {
    try {
      final a = _account(captured.key);
      return a.registrationId == captured.registrationId &&
          a.uid == captured.uid &&
          a.realm == captured.realm;
    } on ZcodeFailure {
      return false;
    }
  }

  Future<void> _exclusive(
    String key, {
    required bool submit,
    bool bindingOnly = false,
    Future<String?> Function(ZcodeCaptchaConfig)? verify,
  }) async {
    final account = _account(key);
    final lock =
        '${accounts.store.identity}\u0000${zcodeRewardIdentity(account.realm, account.uid)}';
    if (!_writers.add(lock)) throw const ZcodeFailure('busy');
    try {
      final session = _RewardSession(this, account);
      await session.load();
      await _run(
        session,
        submit: submit,
        bindingOnly: bindingOnly,
        verify: verify,
      );
    } finally {
      _writers.remove(lock);
    }
  }

  Future<void> _run(
    _RewardSession s, {
    required bool submit,
    required bool bindingOnly,
    Future<String?> Function(ZcodeCaptchaConfig)? verify,
  }) async {
    try {
      await s.bind();
      if (bindingOnly) {
        await s.save();
        return;
      }
      var recovered = false;
      for (final entry in s.claims) {
        final claim = entry.value, state = claim['state'];
        if (state == 'throttled' || state == 'notSubmitted') continue;
        s.recordRejection(claim);
        recovered |= state != claim['state'];
      }
      if (s.held) {
        if (s.reward['planId'] == null && s.reward['status'] != 'throttled') {
          s.setStatus('throttled');
          recovered = true;
        }
        if (recovered) await s.save();
        return;
      }
      var balance = await s.balance();
      s.reconcile(balance);
      final offers = zcodeMarketingOffers(
        await s.request(ZcodeApi.marketingPath),
      )..sort((a, b) => b.priority.compareTo(a.priority));
      ZcodeOffer? selected;
      ({String state, String planId})? blocked;
      for (final offer in offers) {
        final state = s.offerState(
          offer.id,
          balance,
          canVerify: submit && verify != null,
        );
        if (state == 'claimable') {
          selected = offer;
          break;
        }
        blocked ??= (state: state, planId: offer.id);
      }
      if (selected == null) {
        s.setStatus(blocked?.state ?? 'noOffer', blocked?.planId);
        s.reward.remove('rateLimit');
        await s.save();
        return;
      }
      s.setStatus('claimable', selected.id);
      if (!submit) {
        await s.save();
        return;
      }
      var config = _verificationConfig(await s.request(ZcodeApi.configPath));
      for (var attempt = 0; attempt < 2; attempt++) {
        ZcodeVerification? verification;
        if (config != null) {
          if (s.reward['claims'][selected.id]?['state'] !=
              'verificationRequired') {
            s.replaceClaim(selected.id, {
              'state': 'verificationRequired',
              'previous': _instances(balance),
            });
          }
          s.setStatus('verificationRequired', selected.id);
          await s.save();
          if (verify == null) return;
          final proof = await verify(config);
          s.check();
          if (proof == null) return;
          verification = ZcodeVerification(proof, config.values['region']!);
          balance = await s.balance();
          if (balance.active(selected.id) != null) {
            s.reward['claims'][selected.id]['state'] = 'observedClaimed';
            s.reconcile(balance);
            s.setStatus('observedClaimed', selected.id);
            await s.save();
            return;
          }
        }
        final claim = await s.beginClaim(selected.id, balance);
        if (claim == null) return;
        var submitted = false;
        try {
          final request = ZcodeRequest(
            ZcodeApi.claimPath,
            await s.boundToken(),
            s.context,
            {'plan_id': selected.id},
            verification,
          );
          submitted = true;
          final reply = await api.send(
            request,
            isCurrent: () => _current(s.account),
          );
          s.recordReply(selected.id, claim, reply);
        } on ZcodeFailure catch (e) {
          if (!submitted || e.beforeDispatch) {
            await s.recordNotSubmitted(selected.id, e);
            if (_cancelled(e)) rethrow;
            return;
          }
          if (_cancelled(e)) rethrow;
          claim['errorCode'] = e.code;
          claim['httpStatus'] = e.httpStatus;
          claim['serviceCode'] = e.serviceCode;
          if (e.retryAfterMs != null) claim['retryAfterMs'] = e.retryAfterMs;
          if (e.httpStatus != null) claim['answeredAt'] = now();
          s.recordRejection(claim);
        }
        s.setStatus(claim['state'], selected.id);
        await s.save(); // The POST receipt survives a failed balance read.
        if ({
          'rejected',
          'ineligible',
          'throttled',
          'authorization_required',
        }.contains(claim['state']))
          return;
        try {
          balance = await s.balance();
          s.reconcile(balance);
        } on ZcodeFailure catch (e) {
          if (_cancelled(e)) rethrow;
          if (e.httpStatus == 429 || e.serviceCode == 3002) {
            s.rateLimit(e.retryAfterMs);
          }
        }
        s.setStatus(claim['state'], selected.id);
        if (!s.held) s.reward.remove('rateLimit');
        await s.save();
        if (claim['state'] != 'verificationRequired' ||
            verify == null ||
            verification != null)
          return;
        config = _verificationConfig(await s.request(ZcodeApi.configPath));
        if (config == null) return;
      }
    } on ZcodeFailure catch (e) {
      if (_cancelled(e) || e.code == 'storage_unavailable') rethrow;
      if (e.httpStatus == 429 || e.serviceCode == 3002)
        s.rateLimit(e.retryAfterMs);
      s.setStatus(switch (e.code) {
        'authorization_required' => 'authorization_required',
        'invalid_response' => 'discoveryIncomplete',
        'device_required' => 'device_required',
        _ => s.held ? 'throttled' : 'unavailable',
      });
      await s.save();
      rethrow;
    }
  }
}

class _RewardSession {
  _RewardSession(this.owner, this.account);
  final PluginZcodeRewards owner;
  final PluginAccount account;
  late Map<String, dynamic> reward;
  late Map<String, String> context;
  late String _persisted;
  List<CreditExpiryEvidence> _expiryEvidence = const [];
  late Map<String, dynamic> _snapshot;

  void check() {
    if (!owner._current(account)) throw const ZcodeFailure('cancelled');
  }

  Future<Map<String, dynamic>> credential() async {
    check();
    final Map<String, dynamic> auth;
    try {
      auth = await owner.accounts.currentCredential(account.key);
    } catch (_) {
      check();
      throw const ZcodeFailure('credential_unavailable');
    }
    check();
    try {
      final state = jsonDecode(auth['refresh'] as String);
      if (state is! Map<String, dynamic> ||
          auth['uid'] != account.uid ||
          state['site'] != account.realm ||
          !zcodeText(state['jwt'], 16384)) {
        throw const ZcodeFailure('authorization_required');
      }
      zcodeDeviceId(state['device']);
      return state;
    } on ZcodeFailure {
      rethrow;
    } catch (_) {
      throw const ZcodeFailure('authorization_required');
    }
  }

  Future<void> load() async {
    try {
      final data = (await owner.accounts.store.read()).data;
      _checkStored(data);
      _snapshot = data;
      // A write can commit and lose its acknowledgement. The cached account
      // snapshot is not authoritative for a second attempt, even in one process.
      reward = _journal(data, account);
      _persisted = jsonEncode(reward);
    } on ZcodeFailure {
      rethrow;
    } catch (_) {
      throw const ZcodeFailure('storage_unavailable');
    }
  }

  Future<void> bind() async {
    final state = await credential();
    final saved = reward['context'];
    final previous = saved is Map
        ? zcodeContext(Map<String, dynamic>.from(saved))
        : null;
    Map<String, String> supplied;
    if (owner.contextFor != null) {
      try {
        supplied = await owner.contextFor!(
          account,
          await owner.accounts.currentCredential(account.key),
        );
      } on ZcodeFailure {
        rethrow;
      } catch (_) {
        check();
        throw const ZcodeFailure('client_context_unavailable');
      }
      check();
    } else if (previous != null) {
      supplied = previous;
    } else {
      throw const ZcodeFailure('device_required');
    }
    context = zcodeContext({...supplied, 'deviceMid': state['device']});
    if (previous != null &&
        previous.entries.any((e) => context[e.key] != e.value)) {
      (reward['bindingHistory'] as List).add({
        'context': previous,
        'claims': reward['claims'],
        'changedAt': owner.now(),
      });
      reward['claims'] = <String, dynamic>{};
    }
    reward['context'] = context;
    // Validate history before any network or publication; malformed history
    // must never be discarded or treated as permission to claim again.
    for (final entry in claims) {
      if (!zcodeText(entry.key) ||
          entry.value['state'] is! String ||
          entry.value['previous'] is! List ||
          !(entry.value['previous'] as List).every(zcodeText)) {
        throw const ZcodeFailure('storage_unavailable');
      }
    }
  }

  Iterable<MapEntry<String, Map<String, dynamic>>> get claims sync* {
    for (final binding in _bindings(reward)) {
      final source = binding['claims'];
      if (source is! Map) throw const ZcodeFailure('storage_unavailable');
      for (final e in source.entries) {
        if (e.key is! String || e.value is! Map<String, dynamic>) {
          throw const ZcodeFailure('storage_unavailable');
        }
        yield MapEntry(e.key, e.value);
      }
    }
  }

  bool get held =>
      reward['rateLimit']?['retryAt'] is int &&
          reward['rateLimit']['retryAt'] > owner.now() ||
      claims.any(
        (e) =>
            e.value['state'] == 'throttled' &&
            e.value['retryAt'] is int &&
            e.value['retryAt'] > owner.now(),
      );

  Future<String> boundToken() async {
    final state = await credential();
    if (zcodeDeviceId(state['device']) != context['deviceMid']) {
      throw const ZcodeFailure('cancelled');
    }
    return state['jwt'];
  }

  Future<Map<String, dynamic>> request(String path) async => owner.api.request(
    path,
    await boundToken(),
    context,
    isCurrent: () => owner._current(account),
  );

  Future<ZcodeBalance> balance() async {
    final b = ZcodeBalance.parse(
      await request(ZcodeApi.balancePath),
      owner.now(),
    );
    reward['buckets'] = b.buckets.map((b) => b.toJson()).toList();
    _expiryEvidence = b.expiryEvidence;
    reward['plans'] = b.plans;
    reward['checkedAt'] = b.checkedAt;
    return b;
  }

  void reconcile(ZcodeBalance balance) {
    for (final entry in claims) {
      final c = entry.value;
      final existing = c['state'] == 'observedClaimed';
      final confirmed = existing || c['state'] == 'claimed';
      if (!_unknown(c) && !confirmed) continue;
      if (confirmed && c['endsAt'] != null && c['instance'] != null) continue;
      final receipt = balance.receipt(
        entry.key,
        existing ? const [] : c['previous'],
        instance: c['instance'],
        heldOnly: existing && c['instance'] == null,
      );
      if (receipt != null)
        _confirmed(c, receipt, state: existing ? 'observedClaimed' : 'claimed');
    }
  }

  String offerState(
    String id,
    ZcodeBalance balance, {
    required bool canVerify,
  }) {
    final history = claims.where((e) => e.key == id).map((e) => e.value);
    if (balance.active(id) != null ||
        history.any(
          (c) =>
              {'claimed', 'observedClaimed'}.contains(c['state']) &&
              (c['endsAt'] is! int || c['endsAt'] > balance.serverTime),
        )) {
      return 'observedClaimed';
    }
    if (history.any(_unknown)) return 'pending';
    final deviceState = _deviceClaimStatus(_snapshot, id, balance.serverTime);
    if (deviceState != null) return deviceState;
    if (!canVerify) {
      final current = reward['claims'][id];
      final attempts = current is Map<String, dynamic> ? [current] : history;
      for (final claim in attempts) {
        final state = claim['state'];
        if (state == 'verificationRequired' || state == 'activationRequired')
          return state;
      }
    }
    return 'claimable';
  }

  String? _deviceClaimStatus(
    Map<String, dynamic> data,
    String planId,
    int serverTime,
  ) {
    var pending = false;
    for (final journal in _otherRewardSources(data, account)) {
      for (final binding in _bindings(journal)) {
        final device = binding['context']?['deviceMid'];
        if (device is! String || device.toLowerCase() != context['deviceMid'])
          continue;
        final claim = binding['claims']?[planId];
        if (claim is! Map) continue;
        if (claim['state'] == 'claimed' &&
            (claim['endsAt'] is! int || claim['endsAt'] > serverTime)) {
          return 'deviceClaimed';
        }
        pending |= _unknown(claim);
      }
    }
    return pending ? 'devicePending' : null;
  }

  Future<Map<String, dynamic>?> beginClaim(
    String id,
    ZcodeBalance balance,
  ) async {
    Map<String, dynamic>? intent;
    // All accounts share one durable facts store. Check the device and write
    // the intent in the same commit, including after a captcha or restart.
    await save(
      prepare: (data) {
        final blocked = _deviceClaimStatus(data, id, balance.serverTime);
        if (blocked != null) {
          setStatus(blocked, id);
          return;
        }
        intent = replaceClaim(id, {
          'state': 'pending',
          'previous': _instances(balance),
          'submittedAt': owner.now(),
        });
        setStatus('pending', id);
      },
    );
    return intent;
  }

  void setStatus(String state, [String? planId]) {
    reward['status'] = state;
    if (planId == null) {
      reward.remove('planId');
    } else {
      reward['planId'] = planId;
    }
  }

  Map<String, dynamic> replaceClaim(String id, Map<String, dynamic> next) {
    final previous = reward['claims'][id] as Map<String, dynamic>?;
    if (previous != null) {
      next['attempts'] = [
        ...?previous['attempts'] as List?,
        {
          for (final e in previous.entries)
            if (e.key != 'attempts') e.key: e.value,
        },
      ];
    }
    reward['claims'][id] = next;
    return next;
  }

  void recordReply(String id, Map<String, dynamic> claim, ZcodeReply reply) {
    final code = zcodeCode(reply.body), data = reply.body['data'];
    // Only data.message is user-facing in ZCode, never the diagnostic msg.
    final message = data is Map ? data['message'] : null;
    final reason = message is String && message.trim().isNotEmpty
        ? String.fromCharCodes(message.trim().runes.take(2048))
        : null;
    claim.addAll({
      'httpStatus': reply.status,
      'serviceCode': code,
      'answeredAt': owner.now(),
      if (reply.retryAfterMs != null) 'retryAfterMs': reply.retryAfterMs,
    });
    recordRejection(claim);
    if (_unknown(claim) && reply.status >= 200 && reply.status < 300) {
      final plan = data is Map ? data['plan'] : null;
      final planId = plan is Map ? plan['plan_id'] : null;
      if (code == 0 &&
          plan is Map &&
          (planId == null ||
              planId is String && {'', id}.contains(planId.trim()))) {
        _confirmed(claim, plan);
      } else if (code == 0 && plan == null && reason != null) {
        claim['state'] = 'rejected';
      } else {
        // A gateway body, incomplete envelope or mismatched plan is no receipt.
        claim['errorCode'] = 'invalid_response';
      }
    }
    if (!_unknown(claim) && claim['state'] != 'claimed' && reason != null) {
      claim['message'] = reason;
    }
  }

  void recordRejection(Map<String, dynamic> c) {
    final http = c['httpStatus'], code = c['serviceCode'];
    if (http == 429 || code == 3002) {
      c['state'] = 'throttled';
      rateLimit(
        c['retryAfterMs'] as int?,
        observedAt: c['answeredAt'] as int? ?? c['submittedAt'] as int?,
      );
      c['retryAt'] = reward['rateLimit']['retryAt'];
    } else if ({401, 403}.contains(http) ||
        {401, 403}.contains(code) ||
        c['errorCode'] == 'authorization_required') {
      c['state'] = 'authorization_required';
    } else if (http is int &&
        (http >= 200 && http < 300 || http >= 400 && http < 500) &&
        code is int &&
        code != 0) {
      c['state'] = switch (code) {
        3007 => 'verificationRequired',
        1003 => 'observedClaimed',
        1001 || 1002 || 1004 || 1005 || 3001 => 'ineligible',
        _ => 'rejected',
      };
    }
  }

  void rateLimit(int? instructed, {int? observedAt}) {
    // Pinned native zcode/index.mjs noteRateLimit: use server Retry-After up to
    // its 6h cap; absent evidence doubles the prior wait from 30 minutes.
    final previous = reward['rateLimit']?['waitMs'] as int? ?? 0;
    final proposed = instructed != null && instructed > 0
        ? instructed
        : previous * 2 < 1800000
        ? 1800000
        : previous * 2;
    final wait = proposed > 21600000 ? 21600000 : proposed;
    reward['rateLimit'] = {
      'waitMs': wait,
      'retryAt': (observedAt ?? owner.now()) + wait,
    };
  }

  Future<void> recordNotSubmitted(String id, ZcodeFailure failure) async {
    // A device or registration may have changed. Close only the exact intent
    // that this session durably wrote for the original official identity.
    final identity = zcodeRewardIdentity(account.realm, account.uid);
    try {
      await owner.accounts.edit((data) {
        final journal = data['zcode']?['rewards']?[identity];
        if (journal is! Map ||
            jsonEncode(journal) != _persisted ||
            journal['planId'] != id ||
            journal['claims']?[id]?['state'] != 'pending') {
          throw const ZcodeFailure('cancelled');
        }
        journal['claims'][id]['state'] = 'notSubmitted';
        journal['claims'][id]['errorCode'] = failure.code;
        journal['status'] = failure.code == 'authorization_required'
            ? failure.code
            : 'notSubmitted';
      });
    } on ZcodeFailure {
      rethrow;
    } catch (_) {
      throw const ZcodeFailure('storage_unavailable');
    }
  }

  Future<void> save({void Function(Map<String, dynamic>)? prepare}) async {
    check();
    try {
      await owner.accounts.edit((data) {
        _checkStored(data);
        // A newly migrated profile may bring an unresolved older transaction.
        // Do not overwrite that evidence or publish/dispatch from stale facts.
        if (jsonEncode(_journal(data, account)) != _persisted) {
          throw const ZcodeFailure('cancelled');
        }
        prepare?.call(data);
        updateCreditHistory(
          data,
          creditHistoryOwner(account.facts),
          _expiryEvidence,
          DateTime.fromMillisecondsSinceEpoch(owner.now()),
        );
        final zcode =
            data.putIfAbsent('zcode', () => <String, dynamic>{}) as Map;
        final journals =
            zcode.putIfAbsent('rewards', () => <String, dynamic>{}) as Map;
        journals[zcodeRewardIdentity(account.realm, account.uid)] = _copy(
          reward,
        );
        // Move reward facts, including immutable migration history, into their
        // one owner. Retaining a stale per-profile copy would reimport unknowns
        // after a confirmed receipt and could diverge on the next rebind.
        for (final row in _identityRows(data, account)) {
          row.remove('reward');
          final legacy = row['legacy'];
          if (legacy is Map) {
            for (final field in _rewardFields) {
              legacy.remove(field);
            }
          }
        }
      });
      _persisted = jsonEncode(reward);
    } on ZcodeFailure {
      rethrow;
    } catch (_) {
      throw const ZcodeFailure('storage_unavailable');
    }
  }

  void _checkStored(Map<String, dynamic> data) {
    check();
    final row = (data['accounts'] as Map? ?? {})[account.key];
    if (row is! Map ||
        row['removed'] == true ||
        row['quarantine'] != null ||
        row['registrationId'] != account.registrationId ||
        row['uid'] != account.uid ||
        row['realm'] != account.realm) {
      throw const ZcodeFailure('cancelled');
    }
  }
}

Iterable<Map> _bindings(Map journal) sync* {
  yield journal;
  final history = journal['bindingHistory'] ?? const [];
  if (history is! List) throw const ZcodeFailure('storage_unavailable');
  for (final old in history) {
    if (old is! Map) throw const ZcodeFailure('storage_unavailable');
    yield* _bindings(old);
  }
}

Iterable<Map> _otherRewardSources(
  Map<String, dynamic> data,
  PluginAccount account,
) sync* {
  final journals = data['zcode']?['rewards'] as Map? ?? const {};
  for (final entry in journals.entries) {
    final identity = jsonDecode(entry.key);
    if (identity is List &&
        identity.length == 2 &&
        identity.first == account.realm &&
        identity.last != account.uid) {
      yield entry.value as Map;
    }
  }
  // Migration is lazy. An older profile (including a removed profile) can
  // still own the only receipt for this device.
  for (final row in (data['accounts'] as Map? ?? const {}).values) {
    if (row is! Map ||
        row['provider'] != 'zcode' ||
        row['realm'] != account.realm ||
        row['uid'] == account.uid)
      continue;
    for (final source in [row['reward'], row['legacy']]) {
      if (source is Map) yield source;
    }
  }
}

const _rewardFields = {
  'claims',
  'bindingHistory',
  'buckets',
  'context',
  'status',
  'planId',
  'checkedAt',
  'plans',
  'rateLimit',
};

Iterable<Map> _identityRows(
  Map<String, dynamic> data,
  PluginAccount account,
) sync* {
  for (final row in (data['accounts'] as Map? ?? {}).values) {
    if (row is Map &&
        row['provider'] == 'zcode' &&
        row['uid'] == account.uid &&
        row['realm'] == account.realm) {
      // Removed or quarantined native profiles still carry reward evidence for
      // this official account; their unknown transactions remain relevant.
      yield row;
    }
  }
}

Map<String, dynamic> _journal(
  Map<String, dynamic> data,
  PluginAccount account,
) {
  final stored =
      data['zcode']?['rewards']?[zcodeRewardIdentity(
        account.realm,
        account.uid,
      )];
  final sources = <Object?>[
    if (stored != null) stored,
    for (final row in _identityRows(data, account)) ...[
      if (row['reward'] != null) row['reward'],
      if (row['legacy'] is Map &&
          _rewardFields.any((field) => row['legacy'].containsKey(field)))
        {
          for (final field in _rewardFields)
            if (row['legacy'].containsKey(field)) field: row['legacy'][field],
        },
    ],
  ];
  Map<String, dynamic>? merged;
  for (final source in sources) {
    if (source is! Map) throw const ZcodeFailure('storage_unavailable');
    final incoming = _copy(source);
    incoming.putIfAbsent('claims', () => <String, dynamic>{});
    incoming.putIfAbsent('bindingHistory', () => <dynamic>[]);
    incoming.putIfAbsent('buckets', () => <dynamic>[]);
    if (incoming['claims'] is! Map || incoming['bindingHistory'] is! List) {
      throw const ZcodeFailure('storage_unavailable');
    }
    if (merged == null) {
      merged = incoming;
      continue;
    }
    (merged['bindingHistory'] as List).addAll([
      // Preserve the entire source snapshot and every historical binding; no
      // timestamp or claimed state can silently erase another pending claim.
      {
        for (final e in incoming.entries)
          if (e.key != 'bindingHistory') e.key: e.value,
      },
      ...incoming['bindingHistory'] as List,
    ]);
    if (merged['context'] == null && incoming['context'] != null) {
      merged['context'] = incoming['context'];
    }
    final until = incoming['rateLimit']?['retryAt'];
    final previous = merged['rateLimit']?['retryAt'];
    if (until is int && (previous is! int || until > previous)) {
      merged['rateLimit'] = incoming['rateLimit'];
    }
  }
  return merged ??
      {
        'claims': <String, dynamic>{},
        'bindingHistory': <dynamic>[],
        'buckets': <dynamic>[],
      };
}

Map<String, dynamic> _copy(Object value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
bool _unknown(Map c) => {'pending', 'unknown'}.contains(c['state']);
bool _cancelled(ZcodeFailure e) =>
    {'closed', 'cancelled', 'binding_changed'}.contains(e.code);
List<String> _instances(ZcodeBalance balance) => [
  for (final p in balance.plans)
    if (zcodeText(p['user_plan_id'])) p['user_plan_id'] as String,
];
void _confirmed(
  Map<String, dynamic> claim,
  Map plan, {
  String state = 'claimed',
}) {
  claim['state'] = state;
  final instance = plan['user_plan_id'];
  if (instance is String && zcodeText(instance.trim()))
    claim['instance'] = instance.trim();
  final expiry = zcodePlanExpiry(plan);
  if (expiry != null) claim['endsAt'] = expiry;
}

ZcodeCaptchaConfig? _verificationConfig(Map<String, dynamic> reply) {
  final configs = zcodeData(reply)['configs'];
  if (configs is! Map) throw const ZcodeFailure('verification_unavailable');
  final captcha = configs['captcha'];
  if (captcha == null) return null;
  if (captcha is! Map ||
      captcha.containsKey('enabled') && captcha['enabled'] is! bool) {
    throw const ZcodeFailure('verification_unavailable');
  }
  return captcha['enabled'] == false ? null : ZcodeCaptchaConfig.parse(reply);
}
