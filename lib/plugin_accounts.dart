import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'plugin_runtime.dart';
import 'plugin_credentials.dart';
import 'account_document_store.dart';
import 'account_registration.dart';

/// ZCode activity eligibility belongs to the official regional account, even
/// when the native host exposes separate personal and team profiles.
String zcodeRewardIdentity(String realm, String uid) =>
    jsonEncode([realm, uid]);

/// Daily reward facts belong to the official identity, not a native slot.
String pluginRewardIdentity(String provider, String realm, String uid) =>
    jsonEncode([provider, realm, uid]);

class PluginAccount {
  PluginAccount({
    required this.key,
    required this.facts,
    required this.active,
    required this.models,
    this.usage,
    this.queriedAt,
    this.error,
    this.source,
  });
  final String key;
  final Map<String, dynamic> facts;
  final List<Map<String, dynamic>> models;
  final Map<String, dynamic>? usage;

  /// Time of the last successful official usage read, never a failed attempt.
  final DateTime? queriedAt;
  final String? error;
  final String? source;
  final bool active;
  String get provider => facts['provider'];
  String get uid => facts['uid'] ?? '';
  String get label => facts['label'] ?? uid;
  String get realm => facts['realm'] ?? '';
  String get registrationId => facts['registrationId'];
  bool get automatic => facts['automatic'] == true;
}

/// Data-layer owner of account projections and maintenance. The native host
/// alone writes or refreshes credentials. Getters only expose cached facts.
class PluginAccounts extends ChangeNotifier {
  PluginAccounts({
    required this.runtime,
    required String directory,
    required this.store,
    required this.enabledProviders,
  }) : credentials = PluginCredentials(runtime);
  final PluginRuntime runtime;
  final PluginCredentials credentials;
  final AccountDocumentStore store;
  final Set<String> enabledProviders;
  Map<String, dynamic> _data = {};
  Map<String, Map<String, dynamic>> _native = {};
  Map<String, Map<String, dynamic>> _providers = {};
  final _catalogs = <String, List<Map<String, dynamic>>>{};
  final _usage = <String, Map<String, dynamic>>{};
  final _queried = <String, DateTime>{};
  final _errors = <String, String>{};
  Future<void> _writes = Future.value();
  Future<void>? _refreshing;
  StreamSubscription<Map<String, dynamic>>? _events;
  Timer? _renewal, _catalogTimer, _eventTimer;
  bool _closed = false, _maintaining = false;
  String? error;

  Map<String, Map<String, dynamic>> get providers =>
      Map.unmodifiable(_providers);
  List<PluginAccount> get accounts => List.unmodifiable([
    for (final entry in (_data['accounts'] as Map? ?? {}).entries)
      if (entry.value['removed'] != true)
        PluginAccount(
          key: entry.key,
          facts: _accountFacts(entry.value),
          active: _active(entry.key, entry.value),
          models: _active(entry.key, entry.value)
              ? _catalogs[entry.key] ?? const []
              : const [],
          usage: _active(entry.key, entry.value) ? _usage[entry.key] : null,
          queriedAt: _active(entry.key, entry.value)
              ? _queried[entry.key]
              : null,
          error: _errors[entry.key],
          source:
              _active(entry.key, entry.value) &&
                  _native[entry.key]?['source'] is String
              ? _native[entry.key]!['source'] as String
              : null,
        ),
  ]);

  Map<String, dynamic> _accountFacts(Map row) {
    final facts = Map<String, dynamic>.from(row);
    if (row['provider'] == 'zcode' &&
        row['realm'] is String &&
        row['uid'] is String) {
      final reward =
          _data['zcode']?['rewards']?[zcodeRewardIdentity(
            row['realm'],
            row['uid'],
          )];
      if (reward is Map) {
        // This projection is detached from the sole durable journal. Consumer
        // snapshots cannot mutate the data owner through nested map values.
        facts['reward'] = jsonDecode(jsonEncode(reward));
      }
    }
    if (row['provider'] != 'zcode' &&
        row['provider'] is String &&
        row['realm'] is String &&
        row['uid'] is String) {
      final reward =
          _data['rewards']?[pluginRewardIdentity(
            row['provider'],
            row['realm'],
            row['uid'],
          )];
      if (reward is Map) facts['reward'] = jsonDecode(jsonEncode(reward));
    }
    return Map.unmodifiable(facts);
  }

  Future<void> start() async {
    _data = (await store.read()).data;
    await refresh();
    _events = runtime.events.listen((event) {
      if (!{'auth', 'signIn', 'recovered'}.contains(event['event'])) return;
      _eventTimer?.cancel();
      _eventTimer = Timer(
        const Duration(milliseconds: 500),
        () => unawaited(refresh().catchError((_) {})),
      );
    });
    _renewal = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_maintain()),
    );
    _catalogTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => unawaited(refresh().catchError((_) {})),
    );
  }

  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  Future<void> _refresh() async {
    if (_closed) return;
    try {
      final native = await credentials.all();
      for (final entry in (_data['accounts'] as Map? ?? {}).entries) {
        if (entry.value['removed'] == true && native.containsKey(entry.key)) {
          await runtime.call('signOut', {
            'provider': entry.value['provider'],
            'account': entry.key,
          });
          native.remove(entry.key);
        }
      }
      await _observe(native);
      final connected = {for (final key in native.keys) key.split('#').first};
      // Exclude individual slots before native catalog/renewal hooks. Healthy
      // siblings still populate their own catalog even on a cold start.
      final offAccounts = [
        for (final key in native.keys)
          if (!_active(key, _row(key))) key,
      ];
      final rows = await runtime.call('providers', {
        'off': [
          for (final id in runtime.providerIds)
            if (!enabledProviders.contains(id) || !connected.contains(id)) id,
        ],
        'offAccounts': offAccounts,
      }) as List;
      if (_closed) return;
      // Native model/refresh hooks may have rotated a credential while listing.
      await _observe(await credentials.all());
      _providers = {
        for (final row in rows)
          if (enabledProviders.contains(row['id']))
            row['id']: Map<String, dynamic>.unmodifiable({
              ...Map<String, dynamic>.from(row),
              'accounts': [
                for (final a in row['accounts'] as List)
                  if (_active(a['key'], _row(a['key']))) a,
              ],
            }),
      };
      for (final provider in _providers.values) {
        for (final account in provider['accounts'] as List) {
          if (_closed) return;
          final key = account['key'] as String;
          try {
            final expected = Map<String, dynamic>.from(_row(key)!);
            await _live(key, expected);
            Map? loaded;
            var catalogFailed = account['fellBack'] == true;
            try {
              loaded = await runtime.call('load', {
                'provider': provider['id'],
                'account': key,
              }) as Map;
            } catch (_) {
              catalogFailed = true;
            }
            await _live(key, expected);
            final own = account['models'] as List?;
            List<Map<String, dynamic>>? models;
            if (loaded != null &&
                (account['fellBack'] != true || !_catalogs.containsKey(key))) {
              models = List.unmodifiable([
                for (final model in provider['models'] as List)
                  if (own == null || own.contains(model['id']))
                    Map<String, dynamic>.unmodifiable({
                      ...Map<String, dynamic>.from(model),
                      'url': loaded['baseURL'] != ''
                          ? loaded['baseURL']
                          : model['url'] != ''
                          ? model['url']
                          : provider['api'],
                    }),
              ]);
            }
            Map<String, dynamic>? observedUsage;
            String? usageFailure;
            var signIn = '';
            if (provider['usage'] == true) {
              try {
                final usage = await runtime.call('usage', {
                  'provider': provider['id'],
                  'account': key,
                });
                if (usage is! Map) throw const FormatException('Invalid usage');
                signIn = usage['signIn'] is String ? usage['signIn'] : '';
                if (signIn == 'expired' ||
                    usage['error'] is String &&
                        (usage['error'] as String).trim().isNotEmpty) {
                  usageFailure = signIn == 'expired'
                      ? 'authorization_required'
                      : 'usage_unavailable';
                } else {
                  observedUsage = Map.unmodifiable(
                    Map<String, dynamic>.from(usage),
                  );
                }
              } catch (_) {
                usageFailure = 'usage_unavailable';
              }
            }
            await _live(key, expected);
            if (models != null) _catalogs[key] = models;
            if (observedUsage != null) {
              _usage[key] = observedUsage;
              _queried[key] = DateTime.now();
            }
            if (usageFailure != null &&
                signIn != 'renewed' &&
                (_errors[key] == 'authorization_required' ||
                    _usage[key]?['signIn'] == 'expired'))
              usageFailure = 'authorization_required';
            _errors.remove(key);
            if (catalogFailed) _errors[key] = 'catalog_unavailable';
            if (usageFailure != null) {
              // Keep verified quantities and their original observation time.
              // Error strings may contain private response data; publish only
              // a stable failure and this attempt's native sign-in signal.
              // UI attention can retain known expiry, but a failed RPC cannot
              // replay an old renewal/expiry as a new event to Magpie.
              _usage[key] = Map.unmodifiable({
                ...?_usage[key],
                'error': 'Usage query unavailable',
                'signIn': signIn.isEmpty ? 'kept' : signIn,
              });
              _errors[key] = usageFailure;
            }
          } catch (_) {
            _errors.putIfAbsent(key, () => 'account_unavailable');
          }
        }
      }
      error = null;
    } catch (_) {
      _native = {};
      error = 'catalog_unavailable';
      rethrow;
    } finally {
      if (!_closed) notifyListeners();
    }
  }

  /// Serializes only small facts commits, never a network call or a stream.
  Future<void> edit(void Function(Map<String, dynamic>) change) {
    final next = _writes.then((_) async {
      if (_closed) throw StateError('Account owner closed');
      final snapshot = await store.read();
      change(snapshot.data);
      snapshot.data['version'] = 1;
      try {
        await store.write(snapshot.revision, snapshot.data);
      } catch (_) {
        // A lost acknowledgement may follow a committed removal/opt-out. Read
        // the durable facts before any cached consumer can keep using them.
        try {
          _data = (await store.read()).data;
        } catch (_) {
          _native = {}; // Unreadable facts cannot authorize an account.
        }
        if (!_closed) notifyListeners();
        rethrow;
      }
      _data = snapshot.data;
      if (!_closed) notifyListeners();
    });
    _writes = next.catchError((_) {});
    return next;
  }

  Future<void> setAutomatic(String key, bool enabled) => edit((data) {
    final row = (data['accounts'] as Map)[key] as Map;
    row['automatic'] = enabled;
  });

  Future<void> remove(String key) async {
    await edit((data) {
      final row = (data['accounts'] as Map)[key] as Map;
      row['removed'] = true;
      row['registrationId'] = newAccountRegistrationId();
    });
    await runtime.call('signOut', {
      'provider': key.split('#').first,
      'account': key,
    });
    await refresh();
  }

  Future<void> authorizationSaved(
    String key, {
    String? expectedRegistrationId,
  }) async {
    final auth = await credentials.account(key);
    final provider = key.split('#').first;
    if (!enabledProviders.contains(provider))
      throw StateError('Provider unavailable');
    final identity = _identity(key, auth);
    _native[key] = auth;
    var rejected = false;
    await edit((data) {
      final rows =
          data.putIfAbsent('accounts', () => <String, dynamic>{}) as Map;
      final old = rows[key] as Map?;
      if (expectedRegistrationId != null &&
          (old == null ||
              old['removed'] == true ||
              old['registrationId'] != expectedRegistrationId)) {
        throw StateError('Account registration changed');
      }
      if (identity == null || old != null && !_sameIdentity(key, old, auth)) {
        final row = old ?? _adopted(key, auth);
        row['quarantine'] ??= 'native_identity_mismatch';
        rows[key] = row;
        rejected = true;
        return;
      }
      rows[key] =
          {
              ...?old,
              'provider': identity.provider,
              'uid': identity.uid,
              'realm': identity.realm,
              if (identity.accountId != null) 'accountId': identity.accountId,
              'label': _label(auth),
              'registrationId': newAccountRegistrationId(),
              'automatic': old?['automatic'] ?? identity.uid.isNotEmpty,
            }
            ..remove('quarantine')
            ..remove('removed');
    });
    if (rejected) {
      _discard(key);
      throw StateError('Authorization changed the saved identity');
    }
    await refresh();
    if (!_active(key, _row(key))) throw StateError('Account unavailable');
  }

  /// Checks the current native credential without renewing it. Model requests
  /// use this admission gate; the native fetch path owns their refresh.
  Future<void> verifyCredential(String key) async {
    final row = _row(key);
    if (!_active(key, row)) throw StateError('Account unavailable');
    await _live(key, Map<String, dynamic>.from(row!));
  }

  Future<Map<String, dynamic>> currentCredential(String key) async {
    final row = _row(key);
    if (!_active(key, row) || (row!['uid'] as String).isEmpty)
      throw StateError('Account unavailable');
    final expected = Map<String, dynamic>.from(row);
    await _live(key, expected);
    await runtime.call('keepSignedIn', {
      'provider': key.split('#').first,
      'account': key,
    });
    return _live(key, expected);
  }

  Future<void> _maintain() async {
    if (_closed || _maintaining) return;
    _maintaining = true;
    try {
      for (final account in accounts.where(
        (a) => a.active && a.uid.isNotEmpty,
      )) {
        if (_closed) break;
        try {
          await currentCredential(account.key);
        } catch (_) {
          _errors[account.key] = 'renewal_unavailable';
        }
      }
    } finally {
      _maintaining = false;
    }
  }

  Map? _row(String key) => (_data['accounts'] as Map?)?[key] as Map?;

  bool _active(String key, Map? row) =>
      !_closed &&
      row != null &&
      row['removed'] != true &&
      row['quarantine'] == null &&
      enabledProviders.contains(row['provider']) &&
      _sameIdentity(key, row, _native[key]);

  static bool _sameIdentity(String key, Map row, Map<String, dynamic>? auth) {
    final identity = _identity(key, auth);
    return identity != null &&
        row['provider'] == identity.provider &&
        row['uid'] == identity.uid &&
        row['realm'] == identity.realm &&
        (identity.accountId == null || row['accountId'] == identity.accountId);
  }

  static ({String provider, String uid, String realm, String? accountId})?
  _identity(String key, Map<String, dynamic>? auth) {
    if (auth == null || !{'oauth', 'api'}.contains(auth['type'])) return null;
    final provider = key.split('#').first;
    final uid = auth['uid'];
    if (uid != null && uid is! String) return null;
    if (uid is String && uid.isNotEmpty && uid.trim().isEmpty) return null;
    if (auth['type'] == 'oauth' &&
        (uid == null || (uid as String).trim().isEmpty))
      return null;
    final realm = _realm(provider, auth);
    if (realm == null) return null;
    // API keys have no verified official UID. Their stable native accountId
    // binds the key and prompt scope without treating the fingerprint as a UID.
    final String? accountId;
    if (uid == null || uid == '') {
      final value = auth['accountId'];
      if (value is! String || value.trim().isEmpty) return null;
      accountId = value;
    } else {
      accountId = null;
    }
    return (
      provider: provider,
      uid: uid as String? ?? '',
      realm: realm,
      accountId: accountId,
    );
  }

  static String? _realm(String provider, Map<String, dynamic> auth) {
    // These fields select Qoder's actual enterprise endpoint before its public
    // provider default. Keep the kind as well as its value in the identity.
    if (provider == 'qoder' || provider == 'qoder-cn') {
      for (final field in ['enterpriseHost', 'dedicated', 'vpc']) {
        final value = auth[field];
        if (value == null || value == '') continue;
        return value is String && value.trim().isNotEmpty
            ? '$field:$value'
            : null;
      }
    }
    Object? site;
    try {
      final state = jsonDecode(auth['refresh'] as String);
      if (state is Map) site = state['site'];
    } catch (_) {}
    final metadata = auth['metadata'];
    site ??= metadata is Map ? metadata['site'] : null;
    if (provider == 'zcode')
      return {'bigmodel', 'zai'}.contains(site) ? site as String : null;
    if (provider == 'workbuddy') {
      final domain = auth['domain'];
      if (auth['type'] == 'api' && domain == null) return '';
      return domain is String && domain.trim().isNotEmpty ? domain : null;
    }
    final fixed = switch (provider) {
      'minimax-code' || 'qoder-cn' || 'trae-cn' || 'loomy' => 'cn',
      'minimax-code-global' || 'qoder' || 'trae-global' => 'global',
      _ => null,
    };
    if (fixed != null) return fixed;
    final explicit = site ?? auth['domain'];
    return explicit == null
        ? ''
        : explicit is String
        ? explicit
        : null;
  }

  static Map<String, dynamic> _adopted(String key, Map<String, dynamic> auth) {
    final identity = _identity(key, auth);
    return {
      'provider': key.split('#').first,
      'uid': identity?.uid ?? (auth['uid'] is String ? auth['uid'] : ''),
      'realm': identity?.realm ?? '',
      if (identity?.accountId != null) 'accountId': identity!.accountId,
      'label': _label(auth),
      'registrationId': newAccountRegistrationId(),
      'automatic': identity != null && identity.uid.isNotEmpty,
      if (identity == null) 'quarantine': 'native_identity_mismatch',
    };
  }

  Future<void> _observe(Map<String, Map<String, dynamic>> native) async {
    _native = native;
    await edit((data) {
      final rows =
          data.putIfAbsent('accounts', () => <String, dynamic>{}) as Map;
      for (final entry in native.entries) {
        if (!enabledProviders.contains(entry.key.split('#').first)) continue;
        final row = rows.putIfAbsent(
          entry.key,
          () => _adopted(entry.key, entry.value),
        ) as Map;
        if (!_sameIdentity(entry.key, row, entry.value))
          row['quarantine'] ??= 'native_identity_mismatch';
      }
    });
    for (final key in (_data['accounts'] as Map).keys.cast<String>()) {
      if (!_active(key, _row(key))) _discard(key);
    }
  }

  void _discard(String key) {
    _catalogs.remove(key);
    _usage.remove(key);
    _queried.remove(key);
    _errors[key] = 'account_unavailable';
  }

  Future<Map<String, dynamic>> _live(String key, Map expected) async {
    if (_closed) throw StateError('Account owner closed');
    Map<String, dynamic> auth;
    try {
      auth = await credentials.account(key);
    } catch (_) {
      _native.remove(key);
      _discard(key);
      if (!_closed) notifyListeners();
      throw StateError('Account unavailable');
    }
    _native[key] = auth;
    final row = _row(key);
    if (row != null && !_sameIdentity(key, row, auth)) {
      _discard(key);
      await edit((data) {
        final current = (data['accounts'] as Map)[key] as Map?;
        if (current != null && !_sameIdentity(key, current, auth))
          current['quarantine'] ??= 'native_identity_mismatch';
      });
      throw StateError('Native account identity changed');
    }
    if (!_active(key, row) ||
        row!['registrationId'] != expected['registrationId'] ||
        row['provider'] != expected['provider'] ||
        row['uid'] != expected['uid'] ||
        row['realm'] != expected['realm'] ||
        (row['uid'] == '' && row['accountId'] != expected['accountId'])) {
      throw StateError('Account changed');
    }
    return auth;
  }

  static String _label(Map<String, dynamic> auth) {
    for (final key in [
      'name',
      'cardName',
      'phoneLabel',
      'email',
      'accountId',
    ]) {
      final value = auth[key];
      if (value is String &&
          value.trim().isNotEmpty &&
          !(key == 'accountId' && auth['type'] == 'api'))
        return value.trim();
    }
    final email = auth['metadata'] is Map ? auth['metadata']['email'] : null;
    if (email is String && email.trim().isNotEmpty) return email.trim();
    return 'API key';
  }

  Future<void> close() async {
    _closed = true;
    _renewal?.cancel();
    _catalogTimer?.cancel();
    _eventTimer?.cancel();
    await _events?.cancel();
    await _writes;
    super.dispose();
  }
}
