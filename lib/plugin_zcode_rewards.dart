import 'dart:convert';

import 'plugin_accounts.dart';
import 'zcode_api.dart';
import 'zcode_rewards.dart';

/// Owns only ZCode activity transactions. The native host owns credentials and
/// paid-plan usage; the account scheduler decides when to invoke these methods.
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
    bool automatic = false,
    Future<String?> Function(ZcodeCaptchaConfig)? verify,
  }) => _exclusive(key, submit: true, automatic: automatic, verify: verify);
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

  bool _current(PluginAccount captured, bool automatic) {
    try {
      final a = _account(captured.key);
      return a.registrationId == captured.registrationId &&
          a.uid == captured.uid &&
          a.realm == captured.realm &&
          (!automatic || a.automatic);
    } on ZcodeFailure {
      return false;
    }
  }

  Future<void> _exclusive(
    String key, {
    required bool submit,
    bool automatic = false,
    bool bindingOnly = false,
    Future<String?> Function(ZcodeCaptchaConfig)? verify,
  }) async {
    final account = _account(key);
    final lock =
        '${accounts.store.identity}\u0000${zcodeRewardIdentity(account.realm, account.uid)}';
    if (!_writers.add(lock)) throw const ZcodeFailure('busy');
    try {
      final session = _RewardSession(this, account, automatic);
      await session.open();
      if (bindingOnly) {
        if (session.claims.any((e) => _unknown(e.value))) {
          session.reward['status'] = 'pending';
        }
        await session.save();
      } else {
        await _run(session, submit: submit, verify: verify);
      }
    } finally {
      _writers.remove(lock);
    }
  }

  Future<void> _run(
    _RewardSession s, {
    required bool submit,
    Future<String?> Function(ZcodeCaptchaConfig)? verify,
  }) async {
    try {
      var recovered = false;
      for (final entry in s.claims) {
        if (!_unknown(entry.value)) continue;
        s.recordRejection(entry.value);
        recovered |= !_unknown(entry.value);
      }
      if (recovered) {
        s.reward['status'] = s.claims.any((e) => _unknown(e.value))
            ? 'pending'
            : 'unavailable';
        await s.save();
      }
      if (s.held) return;
      var balance = await s.balance();
      s.reconcile(balance);
      final offers = _marketingOffers(await s.request(ZcodeApi.marketingPath))
        ..sort((a, b) => b.priority.compareTo(a.priority));
      ZcodeOffer? selected;
      String? pause;
      var held = false;
      for (final offer in offers) {
        final history = s.claims
            .where((e) => e.key == offer.id)
            .map((e) => e.value);
        if (history.any(_unknown)) continue;
        if (balance.active(offer.id) != null ||
            history.any(
              (c) =>
                  c['state'] == 'observedClaimed' ||
                  c['state'] == 'claimed' &&
                      (c['endsAt'] is! int || c['endsAt'] > balance.serverTime),
            )) {
          held = true;
          continue;
        }
        final current = s.reward['claims'][offer.id] as Map?;
        if ({
          'verificationRequired',
          'activationRequired',
        }.contains(current?['state'])) {
          pause ??= current!['state'];
          if (!submit || verify == null) continue;
        }
        selected = offer;
        break;
      }
      if (selected == null) {
        s.reward['status'] = s.claims.any((e) => _unknown(e.value))
            ? 'pending'
            : pause ?? (held ? 'observedClaimed' : 'noOffer');
        s.reward.remove('rateLimit');
        await s.save();
        return;
      }
      s.reward['status'] = 'claimable';
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
          s.reward['status'] = 'verificationRequired';
          await s.save();
          if (verify == null) return;
          final proof = await verify(config);
          s.check();
          if (proof == null) return;
          verification = ZcodeVerification(proof, config.values['region']!);
          balance = await s.balance();
          final observed = balance.active(selected.id);
          if (observed != null) {
            _confirmed(s.reward['claims'][selected.id], observed);
            s.reward['status'] = 'observedClaimed';
            await s.save();
            return;
          }
        }
        final claim = s.replaceClaim(selected.id, {
          'state': 'pending',
          'previous': _instances(balance),
          'submittedAt': now(),
        });
        s.reward['status'] = 'pending';
        await s.save(); // Durable intent always precedes the possible POST.
        var authorizationRejected = false;
        try {
          final reply = await s.request(
            ZcodeApi.claimPath,
            body: {'plan_id': selected.id},
            verification: verification,
          );
          claim['httpStatus'] = 200;
          claim['serviceCode'] = zcodeCode(reply);
        } on ZcodeFailure catch (e) {
          if (_cancelled(e)) rethrow;
          claim['errorCode'] = e.code;
          claim['httpStatus'] = e.httpStatus;
          claim['serviceCode'] = e.serviceCode;
          if (e.retryAfterMs != null) claim['retryAfterMs'] = e.retryAfterMs;
          if (e.code == 'authorization_required') {
            claim['state'] = 'ineligible';
            authorizationRejected = true;
          }
        }
        if (claim['httpStatus'] != null) claim['answeredAt'] = now();
        s.recordRejection(claim);
        s.reward['status'] = authorizationRejected
            ? 'authorization_required'
            : claim['state'] == 'throttled'
            ? 'unavailable'
            : claim['state'];
        await s.save(); // Keep definite rejections even if the following read fails.
        if (claim['state'] == 'throttled' || authorizationRejected) return;
        try {
          balance = await s.balance();
          final receipt = balance.receipt(selected.id, claim['previous']);
          if (receipt != null) {
            _confirmed(claim, receipt);
          } else if (claim['state'] == 'observedClaimed' &&
              balance.active(selected.id) != null) {
            _confirmed(claim, balance.active(selected.id)!);
          }
        } on ZcodeFailure catch (e) {
          if (_cancelled(e)) rethrow;
          if (e.httpStatus == 429 || e.serviceCode == 3002) {
            s.rateLimit(e.retryAfterMs);
          }
          // No receipt means the durable POST remains unknown.
        }
        s.reward['status'] = claim['state'];
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
      s.reward['status'] = s.claims.any((e) => _unknown(e.value))
          ? 'pending'
          : e.code == 'authorization_required'
          ? 'authorization_required'
          : e.code == 'invalid_response'
          ? 'discoveryIncomplete'
          : 'unavailable';
      await s.save();
      rethrow;
    }
  }
}

class _RewardSession {
  _RewardSession(this.owner, this.account, this.automatic);
  final PluginZcodeRewards owner;
  final PluginAccount account;
  final bool automatic;
  late Map<String, dynamic> reward;
  late Map<String, String> context;
  late String _persisted;

  void check() {
    if (!owner._current(account, automatic))
      throw const ZcodeFailure('cancelled');
  }

  Future<Map<String, dynamic>> credential() async {
    check();
    final auth = await owner.accounts.currentCredential(account.key);
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

  Future<void> open() async {
    final state = await credential();
    try {
      final data = (await owner.accounts.store.read()).data;
      _checkStored(data);
      // A write can commit and lose its acknowledgement. The cached account
      // snapshot is not authoritative for a second attempt, even in one process.
      reward = _journal(data, account);
      _persisted = jsonEncode(reward);
    } on ZcodeFailure {
      rethrow;
    } catch (_) {
      throw const ZcodeFailure('storage_unavailable');
    }
    final saved = reward['context'];
    final previous = saved is Map
        ? zcodeContext(Map<String, dynamic>.from(saved))
        : null;
    Map<String, String> supplied;
    if (owner.contextFor != null) {
      supplied = await owner.contextFor!(
        account,
        await owner.accounts.currentCredential(account.key),
      );
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
    Iterable<MapEntry<String, Map<String, dynamic>>> visit(Map binding) sync* {
      final source = binding['claims'];
      if (source is! Map) throw const ZcodeFailure('storage_unavailable');
      for (final e in source.entries) {
        if (e.key is! String || e.value is! Map<String, dynamic>) {
          throw const ZcodeFailure('storage_unavailable');
        }
        yield MapEntry(e.key, e.value);
      }
      final history = binding['bindingHistory'] ?? const [];
      if (history is! List) throw const ZcodeFailure('storage_unavailable');
      for (final old in history) {
        if (old is! Map) throw const ZcodeFailure('storage_unavailable');
        yield* visit(old);
      }
    }

    yield* visit(reward);
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

  Future<Map<String, dynamic>> request(
    String path, {
    Map<String, dynamic>? body,
    ZcodeVerification? verification,
  }) async {
    final state = await credential();
    if (zcodeDeviceId(state['device']) != context['deviceMid']) {
      throw const ZcodeFailure('cancelled');
    }
    return owner.api.request(
      path,
      state['jwt'],
      context,
      body: body,
      verification: verification,
      isCurrent: () => owner._current(account, automatic),
    );
  }

  Future<ZcodeBalance> balance() async {
    final b = ZcodeBalance.parse(
      await request(ZcodeApi.balancePath),
      owner.now(),
    );
    reward['buckets'] = b.buckets.map((b) => b.toJson()).toList();
    reward['plans'] = b.plans;
    reward['checkedAt'] = b.checkedAt;
    return b;
  }

  void reconcile(ZcodeBalance balance) {
    for (final entry in claims) {
      final c = entry.value;
      if (!_unknown(c)) continue;
      final receipt = balance.receipt(entry.key, c['previous']);
      if (receipt != null) {
        _confirmed(c, receipt);
      }
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

  void recordRejection(Map<String, dynamic> c) {
    final http = c['httpStatus'], code = c['serviceCode'];
    if (http == 429 || code == 3002) {
      c['state'] = 'throttled';
      rateLimit(
        c['retryAfterMs'] as int?,
        observedAt: c['answeredAt'] as int? ?? c['submittedAt'] as int?,
      );
      c['retryAt'] = reward['rateLimit']['retryAt'];
    } else if ({200, 400}.contains(http)) {
      if (code == 3007) c['state'] = 'verificationRequired';
      if (code == 1003) c['state'] = 'observedClaimed';
      if ({1001, 1002, 1004, 1005, 3001}.contains(code))
        c['state'] = 'ineligible';
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

  Future<void> save() async {
    check();
    try {
      await owner.accounts.edit((data) {
        _checkStored(data);
        // A newly migrated profile may bring an unresolved older transaction.
        // Do not overwrite that evidence or publish/dispatch from stale facts.
        if (jsonEncode(_journal(data, account)) != _persisted) {
          throw const ZcodeFailure('cancelled');
        }
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
        automatic && row['automatic'] != true ||
        row['registrationId'] != account.registrationId ||
        row['uid'] != account.uid ||
        row['realm'] != account.realm) {
      throw const ZcodeFailure('cancelled');
    }
  }
}

const _rewardFields = {
  'claims',
  'bindingHistory',
  'buckets',
  'context',
  'status',
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
void _confirmed(Map<String, dynamic> claim, Map<String, dynamic> plan) {
  if (!zcodeText(plan['user_plan_id'])) return;
  claim['state'] = 'claimed';
  claim['instance'] = plan['user_plan_id'];
  claim['endsAt'] = plan['ends_at'];
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

// Matches the pinned native plugin's marketing-only discovery, including
// actions nested inside banners. The deprecated preview is never requested.
List<ZcodeOffer> _marketingOffers(Map<String, dynamic> reply) {
  final deliveries = zcodeData(reply)['deliveries'];
  if (deliveries == null) return [];
  if (deliveries is! List || deliveries.length > 32) {
    throw const ZcodeFailure('invalid_response');
  }
  final found = <String, ZcodeOffer>{};
  for (final delivery in deliveries) {
    if (delivery is! Map) throw const ZcodeFailure('invalid_response');
    void visit(Object? node, int depth) {
      if (depth > 12) return;
      if (node is List) {
        for (final child in node) {
          visit(child, depth + 1);
        }
      }
      if (node is! Map) return;
      if (node['type'] == 'claim_zcode_plan') {
        final id = node['args'] is Map ? node['args']['plan_id'] : null;
        if (!zcodeText(id)) throw const ZcodeFailure('invalid_response');
        found.putIfAbsent(
          id,
          () => ZcodeOffer(
            id,
            null,
            delivery['priority'] is int ? delivery['priority'] : 0,
          ),
        );
      }
      for (final child in node.values) {
        visit(child, depth + 1);
      }
    }

    visit(delivery, 0);
  }
  return found.values.toList();
}
