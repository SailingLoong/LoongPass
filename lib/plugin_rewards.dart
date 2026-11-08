import 'dart:async';
import 'dart:convert';

import 'account_registration.dart';
import 'plugin_accounts.dart';
import 'plugin_zcode_rewards.dart';

const _definitive = {'claimed', 'done', 'ineligible', 'inactive', 'captcha'};

/// Owns scheduling and durable check-in intents, never supplier protocols or
/// credentials. The native host executes hooks; PluginAccounts owns facts.
class PluginRewards {
  PluginRewards(
    this.accounts, {
    PluginZcodeRewards? zcode,
    DateTime Function()? now,
    this.timers = true,
  }) : zcode = zcode ?? PluginZcodeRewards(accounts),
       now = now ?? DateTime.now;
  final PluginAccounts accounts;
  final PluginZcodeRewards zcode;
  final DateTime Function() now;
  final bool timers;
  static final _queues = <String, Future<void>>{};
  final _operations = <Future<void>>{};
  Timer? _periodic, _changedTimer;
  bool _closed = false, _started = false, _ticking = false, _again = false;
  String _seen = '';

  Future<void> start() async {
    if (_closed || _started) return;
    _started = true;
    _seen = _signature();
    accounts.addListener(_changed);
    if (timers)
      _periodic = Timer.periodic(
        const Duration(minutes: 15),
        (_) => unawaited(_tick()),
      );
    // Startup owns scheduling, not the duration of supplier network requests.
    _changedTimer = Timer(Duration.zero, () => unawaited(_tick()));
  }

  String _signature() => jsonEncode([
    for (final a in accounts.accounts)
      [
        a.key,
        a.registrationId,
        a.uid,
        a.realm,
        a.active,
        a.automatic,
        accounts.providers[a.provider]?['checkin'],
        accounts.providers[a.provider]?['checkinStatus'],
      ],
  ]);
  void _changed() {
    if (_closed) return;
    final signature = _signature();
    if (signature == _seen) return; // Reward publications do not schedule work.
    _seen = signature;
    _changedTimer?.cancel();
    _changedTimer = Timer(Duration.zero, () => unawaited(_tick()));
  }

  Future<void> _tick() async {
    if (_closed) return;
    if (_ticking) {
      _again = true;
      return;
    }
    _ticking = true;
    try {
      for (final a in accounts.accounts) {
        if (_closed) break;
        if (!_eligible(a)) continue;
        try {
          if (a.automatic) {
            await claim(a.key, automatic: true);
          } else if (a.provider != 'zcode') {
            await _exclusive(a, () async {
              await _prepare(a, submit: false);
            });
          }
        } catch (_) {
          /* Each account keeps its own durable outcome. */
        }
      }
    } finally {
      _ticking = false;
      if (_again && !_closed) {
        _again = false;
        _changedTimer = Timer(Duration.zero, () => unawaited(_tick()));
      }
    }
  }

  bool _eligible(PluginAccount a) =>
      a.active &&
      a.uid.trim().isNotEmpty &&
      a.registrationId.isNotEmpty &&
      accounts.enabledProviders.contains(a.provider) &&
      (a.provider == 'zcode' ||
          accounts.providers[a.provider]?['checkin'] == true);
  PluginAccount _account(String key) {
    if (_closed) throw StateError('Reward owner closed');
    return accounts.accounts.firstWhere(
      (a) => a.key == key && _eligible(a),
      orElse: () => throw StateError('Reward account unavailable'),
    );
  }

  void _check(PluginAccount expected, [Map? row]) {
    // Work accepted before close still drains and may retain its receipt.
    // Public entry points use _account to prevent new work after close.
    final current = accounts.accounts.firstWhere(
      (a) => a.key == expected.key && _eligible(a),
      orElse: () => throw StateError('Reward account unavailable'),
    );
    bool matches(Map facts) =>
        facts['provider'] == expected.provider &&
        facts['registrationId'] == expected.registrationId &&
        facts['uid'] == expected.uid &&
        facts['realm'] == expected.realm &&
        (facts['automatic'] == true) == expected.automatic &&
        facts['removed'] != true &&
        facts['quarantine'] == null;
    if (!matches(current.facts) || row != null && !matches(row)) {
      throw StateError('Reward account changed');
    }
  }

  Future<void> _exclusive(
    PluginAccount account,
    Future<void> Function() action,
  ) {
    final lock =
        '${accounts.store.identity}\u0000${pluginRewardIdentity(account.provider, account.realm, account.uid)}';
    final previous = _queues[lock] ?? Future<void>.value();
    final work = previous.then((_) {}, onError: (_) {}).then((_) async {
      _check(account);
      await action();
    });
    late final Future<void> finished;
    finished = work.whenComplete(() {
      if (identical(_queues[lock], finished)) _queues.remove(lock);
      _operations.remove(finished);
    });
    _queues[lock] = finished;
    _operations.add(finished);
    return finished;
  }

  Future<void> claim(String key, {bool automatic = false}) async {
    final account = _account(key);
    if (automatic && !account.automatic) return Future.value();
    return _exclusive(account, () async {
      if (account.provider == 'zcode') {
        await zcode.claim(key, automatic: automatic);
        _check(account);
        return;
      }
      final attempt = await _prepare(
        account,
        submit: true,
        automatic: automatic,
      );
      if (attempt == null) return;
      await accounts.currentCredential(key);
      _check(
        account,
      ); // Last local gate; an already dispatched hook cannot be undone.
      Object? reply;
      try {
        reply = await accounts.runtime.call('checkin', {
          'provider': account.provider,
          'account': key,
          if (attempt['scope'] != null) 'expectedScope': attempt['scope'],
        });
      } catch (_) {
        reply = {
          'outcome': 'failed',
          'message': 'Check-in result unconfirmed; automatic retry is paused',
        };
      }
      _check(account);
      final result = _nativeResult(reply, now());
      await accounts.edit((data) {
        final row = (data['accounts'] as Map)[key] as Map;
        _check(account, row);
        final reward = _journal(data, account);
        if (reward['attemptId'] != attempt['attemptId'] ||
            reward['status'] != 'pending')
          throw StateError('Reward intent changed');
        reward.addAll(result);
        _saveJournal(data, account, reward);
      });
      // Usage is only a balance observation and never reconciles this intent.
      if (_definitive.contains(result['status'])) {
        try {
          await accounts.refresh();
        } catch (_) {
          /* Facts retain the receipt. */
        }
      }
    });
  }

  Future<Map<String, dynamic>?> _prepare(
    PluginAccount account, {
    required bool submit,
    bool automatic = false,
  }) async {
    // Always reread durable facts: an earlier commit may have lost its ack.
    // Supplier reads stay outside the short facts transaction.
    final persisted = (await accounts.store.read()).data;
    final row = (persisted['accounts'] as Map)[account.key] as Map;
    _check(account, row);
    final before = _journal(persisted, account);
    // Migration and mirror removal commit together before any native hook.
    // A lost commit acknowledgement cannot authorize dispatch.
    if (_hasMirrors(persisted, account)) {
      await accounts.edit((data) {
        _check(account, (data['accounts'] as Map)[account.key] as Map);
        if (jsonEncode(_journal(data, account)) != jsonEncode(before)) {
          throw StateError('Reward evidence changed');
        }
        _saveJournal(data, account, before);
      });
    }
    final until = _time(before['until']);
    if (before['status'] != 'pending' &&
        until != null &&
        now().isBefore(until)) {
      return null;
    }
    final supported =
        accounts.providers[account.provider]?['checkinStatus'] == true;
    var status = <String, dynamic>{'outcome': 'unknown'};
    if (supported) {
      await accounts.currentCredential(account.key);
      _check(account);
      try {
        status = _nativeStatus(
          await accounts.runtime.call('checkinStatus', {
            'provider': account.provider,
            'account': account.key,
          }),
        );
      } catch (_) {
        // No claim was dispatched. A failed observation may be retried.
      }
      _check(account);
    }
    final reconciles =
        before['status'] == 'pending' &&
        {'done', 'claimed'}.contains(status['outcome']) &&
        _scope(before['scope']) != null &&
        _scope(before['scope']) == _scope(status['scope']) &&
        !(before['history'] as List).any(_pendingEvidence) &&
        before['uid'] == account.uid &&
        before['realm'] == account.realm;
    if (reconciles) {
      await accounts.currentCredential(account.key);
      _check(account);
    }
    Map<String, dynamic>? attempt;
    await accounts.edit((data) {
      final row = (data['accounts'] as Map)[account.key] as Map;
      _check(account, row);
      final reward = _journal(data, account);
      if (jsonEncode(reward) != jsonEncode(before)) {
        throw StateError('Reward evidence changed');
      }
      _saveJournal(data, account, reward);
      if (reward['status'] == 'pending') {
        // Only official evidence for the exact account and native cycle can
        // resolve an uncertain mutation. Missing/old scope never rearms it.
        if (reconciles) {
          reward.addAll(_nativeResult(status, now()));
          _saveJournal(data, account, reward);
        }
        return;
      }
      final history = [...reward['history'] as List];
      if (reward['attemptId'] != null ||
          reward['source'] == 'legacy' ||
          _definitive.contains(reward['status'])) {
        history.add({
          for (final e in reward.entries)
            if (e.key != 'history') e.key: e.value,
        });
      }
      final identity = {
        'registrationId': account.registrationId,
        'uid': account.uid,
        'realm': account.realm,
      };
      if (_definitive.contains(status['outcome'])) {
        _saveJournal(data, account, {
          ...identity,
          ..._nativeResult(status, now()),
          'history': history,
        });
        return;
      }
      if (!submit || supported && status['outcome'] != 'claimable') {
        _saveJournal(data, account, {
          ...identity,
          'status': 'unavailable',
          'outcome': status['outcome'],
          if (status['outcome'] == 'unknown' && supported)
            'message': 'Check-in status unavailable; retry later',
          if (_time(status['until']) case final boundary?)
            'until': boundary.toIso8601String(),
          'observedAt': now().millisecondsSinceEpoch,
          'history': history,
        });
        return;
      }
      // Unsupported status (e.g. Loomy) permits the initial daily attempt.
      // Its uncertain write remains pending forever without native proof.
      attempt = {
        'attemptId': newAccountRegistrationId(),
        if (_scope(status['scope']) case final scope?) 'scope': scope,
      };
      _saveJournal(data, account, {
        ...identity,
        ...attempt!,
        'status': 'pending',
        'submittedAt': now().millisecondsSinceEpoch,
        'automatic': automatic,
        'history': history,
      });
    });
    return attempt;
  }

  Future<void> refresh(String key) async {
    final account = _account(key);
    return _exclusive(account, () async {
      if (account.provider == 'zcode') {
        await zcode.refresh(key);
      } else {
        await _prepare(account, submit: false);
        _check(account);
        await accounts.refresh();
      }
      _check(account);
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _periodic?.cancel();
    _changedTimer?.cancel();
    if (_started) accounts.removeListener(_changed);
    await zcode.close();
    await Future.wait(_operations.toList().map((f) => f.catchError((_) {})));
  }
}

// Official identity is the sole owner across native slot replacement. Legacy
// snapshots are moved once, together with removal of their writable mirrors.
const _legacyRewardFields = {
  'operation',
  'previousSuccessfulOperation',
  'unresolvedOperations',
  'claims',
  'journals',
  'journal',
  'status',
  'outcome',
  'lastOutcome',
};

Iterable<Map> _identityRows(Map data, PluginAccount account) sync* {
  for (final row in (data['accounts'] as Map? ?? {}).values) {
    if (row is Map &&
        row['provider'] == account.provider &&
        row['realm'] == account.realm &&
        row['uid'] == account.uid) {
      yield row;
    }
  }
}

bool _legacyEvidence(Map row) => row['legacy'] is Map
    ? _legacyRewardFields.any((field) => row['legacy'].containsKey(field))
    : row['legacy'] != null;

bool _hasMirrors(Map data, PluginAccount account) => _identityRows(
  data,
  account,
).any((row) => row['reward'] != null || _legacyEvidence(row));

bool _pendingEvidence(Object? value) =>
    value is Map &&
    {
      'pending',
      'unknown',
      'unconfirmed',
      'intent',
    }.contains(value['status'] ?? value['state'] ?? value['outcome']);

Map<String, dynamic> _journal(Map data, PluginAccount account) {
  final stored =
      data['rewards']?[pluginRewardIdentity(
        account.provider,
        account.realm,
        account.uid,
      )];
  final sources = <Map<String, dynamic>>[];
  void add(Object value) {
    final reward = _copy(value);
    if (reward['history'] is! List ||
        !{
          ..._definitive,
          'pending',
          'unavailable',
        }.contains(reward['status']) ||
        _definitive.contains(reward['status']) &&
            _time(reward['until']) == null) {
      throw StateError('Invalid reward record');
    }
    sources.add(reward);
  }

  if (stored != null) add(stored);
  for (final row in _identityRows(data, account)) {
    if (row['reward'] != null) add(row['reward']);
    if (_legacyEvidence(row)) {
      add({
        ..._legacyReward(row['legacy']),
        'source': 'legacy',
        'legacyEvidence': row['legacy'],
      });
    }
  }
  if (sources.isEmpty) return {'status': 'unavailable', 'history': <dynamic>[]};
  if (sources.length == 1 &&
      !(sources.single['history'] as List).any(_pendingEvidence)) {
    return sources.single;
  }
  final evidence = <Map<String, dynamic>>[];
  final seen = <String>{};
  void retain(Object? value) {
    if (value is! Map) throw StateError('Invalid reward history');
    final entry = _copy(value)..remove('history');
    if (seen.add(jsonEncode(entry))) evidence.add(entry);
  }

  for (final source in sources) {
    retain(source);
    for (final entry in source['history'] as List) retain(entry);
  }
  // Every unknown dominates receipts, independent of age. For known cycles,
  // the furthest boundary prevents replay; all other evidence stays archived.
  var selected = evidence.first;
  for (final entry in evidence) {
    if (_pendingEvidence(selected)) break;
    if (_pendingEvidence(entry) ||
        (_time(entry['until'])?.millisecondsSinceEpoch ?? 0) >
            (_time(selected['until'])?.millisecondsSinceEpoch ?? 0)) {
      selected = entry;
    }
  }
  evidence.remove(selected);
  return {
    ...selected,
    if (_pendingEvidence(selected)) 'status': 'pending',
    'history': evidence,
  };
}

void _saveJournal(Map data, PluginAccount account, Map reward) {
  final journals =
      data.putIfAbsent('rewards', () => <String, dynamic>{}) as Map;
  journals[pluginRewardIdentity(account.provider, account.realm, account.uid)] =
      _copy(reward);
  for (final row in _identityRows(data, account)) {
    row.remove('reward');
    final legacy = row['legacy'];
    if (legacy is Map) {
      for (final field in _legacyRewardFields) legacy.remove(field);
    } else if (legacy != null) {
      row.remove(
        'legacy',
      ); // Raw malformed evidence is retained in the journal.
    }
  }
}

Map<String, dynamic> _copy(Object value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
DateTime? _time(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;
String? _scope(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

Map<String, dynamic> _nativeStatus(Object? value) {
  if (value is! Map ||
      !{'claimable', 'unknown', ..._definitive}.contains(value['outcome']) ||
      ['credit', 'streak'].any(
        (k) =>
            value[k] != null &&
            (value[k] is! num || !(value[k] as num).isFinite || value[k] < 0),
      )) {
    return {'outcome': 'unknown'};
  }
  return Map<String, dynamic>.from(value);
}

DateTime _nextDay(DateTime value) {
  final beijing = value.toUtc().add(const Duration(hours: 8));
  return DateTime.utc(
    beijing.year,
    beijing.month,
    beijing.day + 1,
  ).subtract(const Duration(hours: 8));
}

Map<String, dynamic> _nativeResult(Object? value, DateTime observed) {
  if (value is! Map ||
      !{..._definitive, 'failed'}.contains(value['outcome']) ||
      ['credit', 'streak'].any(
        (k) =>
            value[k] != null &&
            (value[k] is! num || !(value[k] as num).isFinite || value[k] < 0),
      )) {
    return {
      'status': 'pending',
      'outcome': 'failed',
      'message': 'Native check-in reply could not be verified',
    };
  }
  final known = _definitive.contains(value['outcome']);
  final text = value['message'] is String
      ? (value['message'] as String).replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      : '';
  final until = _time(value['until']);
  return {
    'status': known ? value['outcome'] : 'pending',
    'outcome': value['outcome'],
    if (known && _scope(value['scope']) != null) 'scope': value['scope'],
    if (value['credit'] is num) 'credit': value['credit'],
    if (value['credit'] is num) 'unit': 'credits',
    if (value['streak'] is num) 'streak': value['streak'],
    'message': text.length > 2048 ? text.substring(0, 2048) : text,
    if (known || until != null)
      'until': (until ?? _nextDay(observed)).toIso8601String(),
    'observedAt': observed.millisecondsSinceEpoch,
  };
}

// Frozen legacy evidence stays in facts.legacy. These summaries seed the one
// current reward transaction; no old unknown dispatch is rearmed by a new day.
Map<String, dynamic> _legacyReward(Object? value) {
  final receipts = <Map<String, dynamic>>[], pending = <String>[];
  void add(String path, Object? value, {Object? day}) {
    if (value == null) return;
    if (value is! Map) {
      pending.add(path);
      return;
    }
    final state = value['settled'] ?? value['state'] ?? value['outcome'];
    final status = switch (state) {
      'claimed' => 'claimed',
      'already' ||
      'alreadyClaimed' ||
      'observedClaimed' ||
      'reconciled' => 'done',
      'unavailable' => 'inactive',
      'needsVerification' => 'captcha',
      'rejected' || 'ineligible' => 'ineligible',
      _ => null,
    };
    if (status == null) {
      pending.add(path);
      return;
    }
    final date = value['day'] ?? day;
    DateTime? until;
    if (date is String && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
      final parsed = DateTime.tryParse('${date}T00:00:00Z');
      if (parsed?.toIso8601String().substring(0, 10) == date)
        until = parsed!.add(const Duration(hours: 16));
    }
    final end = value['target'] is Map ? value['target']['endAt'] : null;
    if (end is int && end > 0)
      until = DateTime.fromMillisecondsSinceEpoch(end * 1000, isUtc: true);
    if (until == null) {
      pending.add(path);
      return;
    }
    final credit = value['points'] ?? value['credited'] ?? value['amount'];
    receipts.add({
      'status': status,
      'outcome': status,
      'source': 'legacy',
      'legacyPaths': [path],
      'until': until.toIso8601String(),
      if (credit is num && credit.isFinite && credit >= 0) 'credit': credit,
      if (credit is num && credit.isFinite && credit >= 0) 'unit': 'credits',
    });
  }

  void entries(String path, Object? value) {
    if (value == null) return;
    if (value is! Map) {
      pending.add(path);
      return;
    }
    for (final e in value.entries) {
      add('$path/${e.key}', e.value, day: e.key);
    }
  }

  if (value != null && value is! Map) pending.add('legacy');
  if (value is Map) {
    add('operation', value['operation']);
    add('previousSuccessfulOperation', value['previousSuccessfulOperation']);
    final unresolved = value['unresolvedOperations'];
    if (unresolved is List) {
      for (var i = 0; i < unresolved.length; i++) {
        add('unresolvedOperations/$i', unresolved[i]);
      }
    } else if (unresolved != null) {
      pending.add('unresolvedOperations');
    }
    entries(
      'claims',
      value['claims'],
    ); // Qoder target windows; TRAE daily receipts.
    entries('journals', value['journals']); // Loomy daily intent journal.
    final journal = value['journal'];
    if (journal is Map) {
      add('journal/latest', journal['latest']);
      add('journal/successful', journal['successful']);
    } else if (journal != null) {
      pending.add('journal');
    }
    for (final field in ['status', 'outcome', 'lastOutcome']) {
      if ({
        'pending',
        'unknown',
        'unconfirmed',
        'intent',
      }.contains(value[field]))
        pending.add(field);
    }
  }
  receipts.sort(
    (a, b) => (a['until'] as String).compareTo(b['until'] as String),
  );
  if (pending.isNotEmpty)
    return {
      'status': 'pending',
      'source': 'legacy',
      'legacyPaths': pending,
      'history': receipts,
      'message': 'Earlier check-in remains unconfirmed; native hooks provide no read-only receipt reconciliation',
    };
  if (receipts.isEmpty)
    return {'status': 'unavailable', 'history': <dynamic>[]};
  final latest = receipts.removeLast();
  return {...latest, 'history': receipts};
}
