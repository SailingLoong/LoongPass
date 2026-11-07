import 'dart:async';
import 'dart:convert';
import '../account_document_store.dart';
import '../credit_summary.dart';
import '../claim_receipt.dart';
import 'reward_provider.dart';

class RewardAccount {
  const RewardAccount(
    this.provider,
    this.identity,
    this.label,
    this.automatic,
    this.outcome,
    this.day,
    this.receipt,
    this.credits, {
    this.needsAttention = false,
  });
  final String provider, identity, label, outcome;
  final bool automatic;
  final bool needsAttention;
  final String? day;
  final ClaimReceipt? receipt;
  final CreditSummary? credits;
}

/// Sole owner of saved sessions, daily intents, balance snapshots and timers.
/// UI reads are synchronous and never refresh or initiate a reward request.
class RewardAccounts {
  RewardAccounts({
    required this.store,
    required List<RewardProvider> providers,
    required RewardTransport Function(RewardProvider) transportFor,
    DateTime Function()? now,
  }) : providers = {for (final provider in providers) provider.id: provider},
       transports = {
         for (final provider in providers) provider.id: transportFor(provider),
       },
       now = now ?? DateTime.now {
    if (this.providers.length != providers.length) {
      throw ArgumentError('Duplicate reward provider');
    }
  }
  final AccountDocumentStore store;
  final Map<String, RewardProvider> providers;
  final Map<String, RewardTransport> transports;
  final DateTime Function() now;
  final _changes = StreamController<void>.broadcast(sync: true);
  final _credits = <String, CreditSummary>{};
  final _attention = <String>{};
  Map<String, dynamic> _data = {
    'version': 1,
    'accounts': <String, dynamic>{},
    'journals': <String, dynamic>{},
  };
  bool _busy = false, _closed = false, _ticking = false;
  Timer? _startup, _automatic, _poll;
  RewardLogin? _login;
  String? _loginProvider, _error;
  int _loginEpoch = 0;
  Stream<void> get changes => _changes.stream;
  bool get busy => _busy;
  String? get loginProvider => _loginProvider;
  String? get error => _error;
  String _key(String provider, String identity) =>
      jsonEncode([provider, identity]);
  void _notify() {
    if (!_closed) _changes.add(null);
  }

  List<RewardAccount> accountsFor(String provider) {
    final rows = _data['accounts'] as Map;
    final journals = _data['journals'] as Map;
    return List.unmodifiable([
      for (final entry in rows.entries)
        if (entry.value['provider'] == provider)
          _snapshot(entry.key as String, entry.value as Map, journals),
    ]);
  }

  RewardAccount _snapshot(String key, Map row, Map journals) {
    final days = Map<String, dynamic>.from(journals[key] as Map? ?? {});
    final dates = days.keys.toList()..sort();
    final day = dates.lastOrNull;
    final latest = day == null ? null : days[day] as Map;
    ClaimReceipt? receipt;
    for (final date in dates.reversed) {
      final value = days[date] as Map;
      if (value['state'] != 'claimed') continue;
      receipt = ClaimReceipt(
        amount: value['amount'] as num?,
        day: date,
        confirmedAt: value['confirmedAt'] is int
            ? DateTime.fromMillisecondsSinceEpoch(value['confirmedAt'] as int)
            : null,
      );
      break;
    }
    final state = latest?['state'] as String? ?? 'pending';
    return RewardAccount(
      row['provider'] as String,
      row['identity'] as String,
      row['label'] as String,
      row['automatic'] == true,
      state == 'intent' ? 'unknown' : state,
      day,
      receipt,
      _credits[key],
      needsAttention:
          _attention.contains(key) ||
          state == 'intent' ||
          state == 'unknown' ||
          state == 'rejected',
    );
  }

  Future<T> _run<T>(Future<T> Function() action) async {
    if (_closed) throw const RewardFailure('closed');
    if (_busy) throw const RewardFailure('busy');
    _busy = true;
    _error = null;
    _notify();
    try {
      return await action();
    } on RewardFailure catch (failure) {
      _error = failure.code;
      rethrow;
    } catch (_) {
      _error = 'operation_unavailable';
      throw const RewardFailure('operation_unavailable');
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> _accountRun(
    String provider,
    String identity,
    Future<void> Function() action,
  ) => _run(() async {
    final key = _key(provider, identity);
    _attention.remove(key);
    try {
      await action();
    } catch (_) {
      _attention.add(key);
      rethrow;
    }
  });

  Future<AccountDocument> _read() async {
    try {
      final doc = await store.read();
      if (doc.data.isEmpty) {
        doc.data.addAll({
          'version': 1,
          'accounts': <String, dynamic>{},
          'journals': <String, dynamic>{},
        });
      }
      final value = doc.data;
      if (value['version'] != 1 ||
          value['accounts'] is! Map<String, dynamic> ||
          value['journals'] is! Map<String, dynamic>) {
        throw const FormatException();
      }
      for (final entry in (value['accounts'] as Map).entries) {
        final row = entry.value;
        if (row is! Map ||
            !_text(row['provider']) ||
            !_text(row['identity']) ||
            !_text(row['label']) ||
            row['credentials'] is! Map<String, dynamic> ||
            row['automatic'] is! bool ||
            entry.key !=
                _key(row['provider'] as String, row['identity'] as String)) {
          throw const FormatException();
        }
      }
      for (final journal in (value['journals'] as Map).values) {
        if (journal is! Map) throw const FormatException();
        for (final day in journal.entries) {
          final row = day.value;
          if (day.key is! String ||
              !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day.key as String) ||
              row is! Map ||
              !{
                'intent',
                'unknown',
                'claimed',
                'already',
                'unavailable',
                'rejected',
              }.contains(row['state']) ||
              row['amount'] != null &&
                  (row['amount'] is! num ||
                      !(row['amount'] as num).isFinite ||
                      row['amount'] < 0)) {
            throw const FormatException();
          }
        }
      }
      _data = _copy(value);
      return doc;
    } catch (_) {
      throw const RewardFailure('storage_unavailable');
    }
  }

  static Map<String, dynamic> _copy(Map<String, dynamic> value) =>
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  static bool _text(Object? value) =>
      value is String &&
      value.trim().isNotEmpty &&
      value.length <= 512 &&
      !value.codeUnits.any((c) => c < 32 || c == 127);
  Future<void> _save(AccountDocument doc) async {
    if (_closed) throw const RewardFailure('closed');
    try {
      await store.write(doc.revision, doc.data);
    } catch (_) {
      throw const RewardFailure('storage_unavailable');
    }
    _data = _copy(doc.data);
  }

  RewardProvider _provider(String id) =>
      providers[id] ?? (throw const RewardFailure('unknown_provider'));
  Map<String, dynamic> _row(
    AccountDocument doc,
    String provider,
    String identity,
  ) {
    final row = (doc.data['accounts'] as Map)[_key(provider, identity)];
    if (row is! Map<String, dynamic>)
      throw const RewardFailure('account_missing');
    return row;
  }

  RewardSession _session(Map row) => RewardSession(
    identity: row['identity'] as String,
    label: row['label'] as String,
    credentials: Map<String, dynamic>.from(row['credentials'] as Map),
  );
  Future<RewardSession> _refresh(String provider, String identity) async {
    final doc = await _read(), row = _row(doc, provider, identity);
    final previous = _session(row), adapter = _provider(provider);
    final next = await adapter.refresh(transports[provider]!, previous);
    if (_closed) throw const RewardFailure('closed');
    if (next.identity != identity || !_text(next.label))
      throw const RewardFailure('identity_mismatch');
    if (jsonEncode(previous.credentials) != jsonEncode(next.credentials) ||
        next.label != previous.label) {
      row['credentials'] = next.credentials;
      row['label'] = next.label;
      await _save(doc);
    }
    return next;
  }

  Future<void> restore() => _run(() async {
    await _read();
  });

  Future<Uri?> beginLogin(String provider, {String? phone}) => _run(() async {
    if (_login != null) throw const RewardFailure('authorization_in_progress');
    final adapter = _provider(provider), epoch = ++_loginEpoch;
    final flow = await adapter.beginLogin(transports[provider]!, phone: phone);
    if (_closed || epoch != _loginEpoch) {
      flow.cancel();
      throw const RewardFailure('cancelled');
    }
    _login = flow;
    _loginProvider = provider;
    if (adapter.loginKind == RewardLoginKind.browser) {
      _poll = Timer.periodic(const Duration(seconds: 2), (_) {
        if (!_closed && !_busy && _login != null) {
          unawaited(completeLogin().catchError((_) => false));
        }
      });
    }
    return flow.url;
  });
  Future<bool> completeLogin({String? verificationCode}) => _run(() async {
    final flow = _login, provider = _loginProvider, epoch = _loginEpoch;
    if (flow == null || provider == null)
      throw const RewardFailure('authorization_missing');
    final session = await flow.poll(verificationCode: verificationCode);
    if (_closed || epoch != _loginEpoch) return false;
    if (session == null) return false;
    if (!_text(session.identity) ||
        !_text(session.label) ||
        session.credentials.isEmpty)
      throw const RewardFailure('invalid_identity');
    final doc = await _read(), rows = doc.data['accounts'] as Map;
    if (_closed || epoch != _loginEpoch) return false;
    final key = _key(provider, session.identity), old = rows[key] as Map?;
    rows[key] = {
      'provider': provider,
      'identity': session.identity,
      'label': session.label,
      'credentials': session.credentials,
      'automatic': old?['automatic'] ?? true,
    };
    await _save(doc);
    cancelLogin();
    _attention.remove(key);
    try {
      _credits[key] = await _provider(
        provider,
      ).credits(transports[provider]!, session);
    } catch (_) {
      _error = 'balance_unavailable';
      _attention.add(key);
    }
    return true;
  });
  void cancelLogin() {
    _loginEpoch++;
    _poll?.cancel();
    _poll = null;
    _login?.cancel();
    _login = null;
    _loginProvider = null;
    _notify();
  }

  Future<void> refreshCredits(String provider, String identity) =>
      _accountRun(provider, identity, () async {
        final session = await _refresh(provider, identity);
        final credits = await _provider(
          provider,
        ).credits(transports[provider]!, session);
        if (!_closed) _credits[_key(provider, identity)] = credits;
      });
  Future<void> setAutomatic(String provider, String identity, bool enabled) =>
      _run(() async {
        final doc = await _read();
        _row(doc, provider, identity)['automatic'] = enabled;
        await _save(doc);
      });
  Future<void> remove(String provider, String identity) => _run(() async {
    final doc = await _read(), key = _key(provider, identity);
    (doc.data['accounts'] as Map).remove(key);
    // Retain the daily journal as a credential-free tombstone. Reauthorizing
    // this official identity must not repeat an unknown or confirmed claim.
    await _save(doc);
    _credits.remove(key);
    _attention.remove(key);
  });
  Future<void> _record(
    String key,
    String day,
    Map<String, dynamic> value,
  ) async {
    final doc = await _read(), journals = doc.data['journals'] as Map;
    final journal = journals.putIfAbsent(key, () => <String, dynamic>{}) as Map;
    journal[day] = value;
    await _save(doc);
  }

  Future<void> claim(String provider, String identity) =>
      _accountRun(provider, identity, () async {
        final adapter = _provider(provider),
            key = _key(provider, identity),
            day = rewardDay(now());
        final doc = await _read();
        _row(doc, provider, identity);
        final previous =
            ((doc.data['journals'] as Map)[key] as Map?)?[day] as Map?;
        final state = previous?['state'];
        if (state == 'claimed' || state == 'already') return;
        final session = await _refresh(provider, identity),
            http = transports[provider]!;
        final offer = await adapter.inspect(http, session, day);
        if (state == 'intent' || state == 'unknown') {
          await _record(key, day, {
            'state': offer.state == RewardState.already ? 'already' : 'unknown',
          });
          return;
        }
        if (offer.state != RewardState.available) {
          if (offer.state != RewardState.already &&
              offer.state != RewardState.unavailable)
            throw const RewardFailure('invalid_offer');
          await _record(key, day, {'state': offer.state.name});
          return;
        }
        await _record(key, day, {'state': 'intent'});
        RewardResult result;
        try {
          result = await adapter.claim(http, session, offer, day);
          if (result.state == RewardState.available ||
              result.amount != null &&
                  (!result.amount!.isFinite || result.amount! < 0)) {
            throw const RewardFailure('invalid_receipt');
          }
        } on RewardRejected {
          await _record(key, day, {'state': 'rejected'});
          rethrow;
        } catch (_) {
          await _record(key, day, {'state': 'unknown'});
          return;
        }
        await _record(key, day, {
          'state': result.state.name,
          if (result.state == RewardState.claimed) 'amount': result.amount,
          if (result.state == RewardState.claimed)
            'confirmedAt': now().millisecondsSinceEpoch,
        });
        try {
          _credits[key] = await adapter.credits(http, session);
        } catch (_) {
          _error = 'balance_unavailable';
          _attention.add(key);
        }
      });

  Future<void> tick() async {
    if (_closed || _busy || _ticking) return;
    _ticking = true;
    try {
      final accounts = [
        for (final provider in providers.keys) ...accountsFor(provider),
      ];
      for (final account in accounts) {
        if (_closed) break;
        try {
          await refreshCredits(account.provider, account.identity);
          if (account.automatic)
            await claim(account.provider, account.identity);
        } catch (_) {
          /* Per-account errors never abort other platforms. */
        }
      }
    } finally {
      _ticking = false;
    }
  }

  Future<void> start() async {
    await restore();
    if (_closed || _automatic != null) return;
    for (final provider in providers.keys) {
      for (final account in accountsFor(provider)) {
        if (_closed) return;
        try {
          await refreshCredits(provider, account.identity);
        } catch (_) {}
      }
    }
    if (_closed) return;
    _startup = Timer(const Duration(seconds: 30), () => unawaited(tick()));
    _automatic = Timer.periodic(
      const Duration(minutes: 15),
      (_) => unawaited(tick()),
    );
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _startup?.cancel();
    _automatic?.cancel();
    cancelLogin();
    unawaited(_changes.close());
    _credits.clear();
  }
}
