import 'claim_receipt.dart';
// Region-bound independent grants and explicit free benefits. MIT-derived protocol:
// candidate-669 qoder_cn_device_login, qoder_http_auth/transport,
// qoder_daily/cn_benefits{,_contract}. No desktop auth-file access.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'qoder_credits.dart';
import 'account_registration.dart';

enum QoderRegion {
  cn(
    'Qoder CN',
    'qoder.cn',
    'openapi.qoder.com.cn',
    'e883ade2-e6e3-4d6d-adf7-f92ceff5fdcb',
  ),
  global(
    'Qoder',
    'qoder.com',
    'openapi.qoder.sh',
    '732aef47-9cf2-46a2-95fe-4cebb5d0d1fa',
  );

  const QoderRegion(this.label, this.authHost, this.apiHost, this.clientId);
  final String label, authHost, apiHost, clientId;
}

abstract interface class QoderNative {
  Future<Map<String, dynamic>> call(String method, Map<String, dynamic> args);
}

abstract interface class QoderTransport {
  Future<QoderResponse> send(
    String method,
    Uri url,
    String? bearer,
    Map<String, dynamic>? body, {
    bool Function()? isCurrent,
  });
}

class QoderResponse {
  final int status;
  final Map<String, dynamic> body;
  final int? serverMs;
  QoderResponse(this.status, this.body, {this.serverMs});
  @override
  String toString() => 'QoderResponse(redacted)';
}

class QoderAccountError implements Exception {
  final String code;
  const QoderAccountError(this.code);
  @override
  String toString() => 'Qoder: $code';
}

class QoderLogin {
  final Uri url;
  QoderLogin(this.url);
  @override
  String toString() => 'QoderLogin(redacted)';
}

/// Production network adapter. Origin is fixed; no redirects, retries or logs.
class QoderHttp implements QoderTransport {
  final QoderRegion region;
  QoderHttp({this.region = QoderRegion.cn});
  @override
  Future<QoderResponse> send(
    String method,
    Uri url,
    String? bearer,
    Map<String, dynamic>? body, {
    bool Function()? isCurrent,
  }) async {
    if (url.scheme != 'https' ||
        url.host != region.apiHost ||
        url.port != 443 ||
        url.userInfo.isNotEmpty ||
        url.fragment.isNotEmpty)
      throw const QoderAccountError('invalid_source');
    var finished = false;
    bool admitted() => !finished && (isCurrent?.call() ?? true);
    if (!admitted()) throw const QoderAccountError('operation_expired');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      return await (() async {
        final req = await client.openUrl(method, url);
        if (!admitted()) {
          req.abort();
          throw const QoderAccountError('operation_expired');
        }
        req.followRedirects = false;
        req.headers.set('Accept', 'application/json');
        req.headers.contentType = ContentType.json;
        final campaign = url.path.startsWith('/sash/');
        req.headers.set('Cosy-ClientType', campaign ? '10' : '5');
        req.headers.set('User-Agent', campaign ? 'Qoder' : 'LoongPass');
        if (!campaign) req.headers.set('Cosy-Version', '1.0.1');
        if (bearer != null) req.headers.set('Authorization', 'Bearer $bearer');
        if (!admitted()) {
          req.abort();
          throw const QoderAccountError('operation_expired');
        }
        if (body != null) req.write(jsonEncode(body));
        final response = await req.close();
        if (response.isRedirect ||
            response.statusCode >= 300 && response.statusCode < 400)
          throw const QoderAccountError('redirect_rejected');
        final bytes = <int>[];
        final limit = campaign ? 262144 : 1048576;
        await for (final chunk in response) {
          if (bytes.length + chunk.length > limit)
            throw const QoderAccountError('response_too_large');
          bytes.addAll(chunk);
        }
        if (response.statusCode == 404 &&
            url.path == '/api/v1/deviceToken/poll')
          return QoderResponse(404, {});
        if (response.statusCode != 200 &&
            url.path == '/api/v1/deviceToken/refresh')
          return QoderResponse(response.statusCode, {});
        if (response.statusCode != 200)
          throw QoderAccountError(
            response.statusCode == 401
                ? 'authentication_required'
                : response.statusCode == 403
                ? 'verification_required'
                : response.statusCode == 429
                ? 'rate_limited'
                : 'http_error',
          );
        final value = jsonDecode(utf8.decode(bytes));
        if (value is! Map<String, dynamic>)
          throw const QoderAccountError('invalid_response');
        int? server;
        try {
          final date = response.headers.value('date');
          if (date != null)
            server = HttpDate.parse(date).millisecondsSinceEpoch;
        } catch (_) {}
        return QoderResponse(response.statusCode, value, serverMs: server);
      })().timeout(const Duration(seconds: 30));
    } on QoderAccountError {
      rethrow;
    } catch (_) {
      throw const QoderAccountError('network_error');
    } finally {
      finished = true;
      client.close(force: true);
    }
  }
}

class _Store {
  int revision;
  final Map<String, dynamic> data;
  _Store(this.revision, this.data);
}

class _Grant {
  final Map<String, dynamic> material;
  final int expires;
  final _Store store;
  int? lastPoll;
  Map<String, dynamic>? authorized;
  bool polling = false;
  _Grant(this.material, this.expires, this.store);
  @override
  String toString() => 'Grant(redacted)';
}

class QoderSavedAccount {
  final String uid, label;
  final bool automatic;
  final int authorizationExpiresAt;
  final String? outcome, registrationId;
  final ClaimReceipt? latestClaim;
  const QoderSavedAccount(
    this.uid,
    this.label,
    this.automatic,
    this.authorizationExpiresAt,
    this.outcome, {
    this.latestClaim,
    this.registrationId,
  });
}

class QoderDeviceAccounts {
  final QoderNative _native;
  final QoderTransport _http;
  final int Function() _now;
  _Grant? _grant;
  String? _commitNonce, _commitOutcome;
  bool _starting = false, _claiming = false;
  int _cancelEpoch = 0;
  QoderDeviceAccounts({
    this.region = QoderRegion.cn,
    required QoderNative native,
    required QoderTransport transport,
    required int Function() nowMs,
  }) : _native = native,
       _http = transport,
       _now = nowMs;
  final QoderRegion region;
  final _authorizationChanges = StreamController<void>.broadcast();
  Stream<void> get authorizationChanges => _authorizationChanges.stream;
  FutureOr<void> Function()? onChanged;
  bool _closed = false, _ticking = false;
  Timer? _pollTimer, _startupTimer, _automaticTimer;
  final _verified = <String, String>{};
  final _blockedAuthorizations = <String, String>{};
  String? message;
  bool get loginPending => _grant != null;
  Future<void> _notify() async {
    if (!_closed) {
      try {
        await onChanged?.call();
      } catch (_) {}
    }
  }

  void followAuthorization() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_closed) return;
      try {
        final uid = await pollLogin();
        if (uid != null) {
          _pollTimer?.cancel();
          _pollTimer = null;
          message = '账号已验证并保存，辅助签到已开启。';
          startAutomatic();
        }
      } on QoderAccountError catch (e) {
        message = loginPending
            ? '授权结果保留中，正在重试身份读取。'
            : '授权未完成（${e.code}），请核对已保存账号。';
        if (!loginPending) {
          _pollTimer?.cancel();
          _pollTimer = null;
        }
      }
      await _notify();
    });
  }

  void startAutomatic() {
    if (_closed || _automaticTimer != null) return;
    unawaited(_refreshAllCredits());
    _startupTimer = Timer(
      const Duration(seconds: 30),
      () => unawaited(automaticTick()),
    );
    _automaticTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => unawaited(automaticTick()),
    );
  }

  Future<void> automaticTick() async {
    if (_closed || _ticking || _grant != null || _starting) return;
    _ticking = true;
    try {
      for (final account in await accountViews()) {
        if (_closed) break;
        if (account.automatic) {
          try {
            await claim(account.uid);
          } on QoderAccountError catch (e) {
            message = '${region.label} 账号检查未完成（${e.code}）。';
          }
        }
        try {
          await refreshCredits(account.uid);
        } catch (_) {
          message = '${region.label} 余额查询未完成。';
        }
      }
    } catch (_) {
      message = '无法读取已保存账号。';
    } finally {
      _ticking = false;
      await _notify();
    }
  }

  Future<void> _refreshAllCredits() async {
    try {
      for (final account in await accountViews()) {
        if (_closed) break;
        try {
          await refreshCredits(account.uid);
        } catch (_) {}
      }
    } catch (_) {
      message = '无法读取已保存账号。';
    } finally {
      await _notify();
    }
  }

  Future<List<QoderSavedAccount>> accountViews() async {
    final store = await _read();
    return [
      for (final e in (store.data['accounts'] as Map<String, dynamic>).entries)
        QoderSavedAccount(
          e.key,
          e.value['label'] ?? e.key,
          e.value['automatic'] == true,
          e.value['expiresAt'],
          e.value['lastOutcome'],
          registrationId: e.value['registrationId'],
          latestClaim: _latestClaim(store.data['claims'] as Map, e.key),
        ),
    ];
  }

  ClaimReceipt? _latestClaim(Map claims, String uid) {
    final success = [
      for (final e in claims.entries)
        if ((jsonDecode(e.key) as List).first == uid)
          if (e.value['state'] == 'claimed')
            e.value as Map
          else if (e.value['previousSuccess'] is Map)
            e.value['previousSuccess'] as Map,
    ];
    if (success.isEmpty) return null;
    final times = [
      for (final c in success)
        if (c['confirmedAtMs'] is int) c['confirmedAtMs'] as int,
    ]..sort();
    return ClaimReceipt(
      confirmedAt: times.isEmpty
          ? null
          : DateTime.fromMillisecondsSinceEpoch(times.last),
    );
  }

  Future<void> setAutomatic(String uid, bool enabled) async {
    if (_closed || _claiming || _grant != null)
      throw const QoderAccountError('busy');
    final s = await _read();
    final a = s.data['accounts'][uid];
    if (a == null) throw const QoderAccountError('identity_required');
    a['automatic'] = enabled;
    await _save(s);
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    unawaited(_authorizationChanges.close());
    _pollTimer?.cancel();
    _startupTimer?.cancel();
    _automaticTimer?.cancel();
    unawaited(cancelLogin());
  }

  Uri _url(String path, [Map<String, String>? query]) =>
      Uri.https(region.apiHost, path, query);
  static bool _text(Object? v, {int max = 16384}) =>
      v is String &&
      v.trim().isNotEmpty &&
      v.length <= max &&
      !v.codeUnits.any((c) => c < 32 || c == 127);
  static bool _uuid(Object? v) =>
      v is String &&
      RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      ).hasMatch(v);
  Future<Map<String, dynamic>> _nativeCall(
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      return await _native.call(method, args);
    } catch (_) {
      throw const QoderAccountError('storage_unavailable');
    }
  }

  Future<_Store> _read() async {
    final raw = await _nativeCall('read', {});
    try {
      final payload = raw['payload'];
      if (raw['revision'] is! int ||
          raw['revision'] < 0 ||
          payload is! String ||
          utf8.encode(payload).length > 1048576)
        throw 0;
      final data = jsonDecode(payload);
      if (data is! Map<String, dynamic>) throw 0;
      if (data.isEmpty) {
        data['accounts'] = <String, dynamic>{};
        data['claims'] = <String, dynamic>{};
      }
      if (data['accounts'] is! Map<String, dynamic> ||
          data['claims'] is! Map<String, dynamic> ||
          (data['accounts'] as Map).length > 100)
        throw 0;
      for (final e in (data['accounts'] as Map<String, dynamic>).entries) {
        final a = e.value;
        if (!_text(e.key, max: 1024) ||
            a is! Map ||
            !_text(a['token']) ||
            !_text(a['refreshToken'] == '' ? 'empty' : a['refreshToken']) ||
            a['expiresAt'] is! int ||
            a['expiresAt'] <= 0 ||
            !_uuid(a['machineId']) ||
            !_uuid(a['generation']) ||
            a['registrationId'] != null &&
                !_text(a['registrationId'], max: 128))
          throw 0;
        for (final name in [
          'authorizationInvalid',
          'accessRejected',
          'refusalRecoveryAttempted',
          'refreshPending',
        ]) {
          if (a.containsKey(name) && a[name] is! bool) throw 0;
        }
      }
      for (final v in (data['claims'] as Map).values) {
        if (v is! Map ||
            !{
              'pending',
              'unknown',
              'claimed',
              'reconciled',
            }.contains(v['state']))
          throw 0;
      }
      return _Store(raw['revision'], data);
    } catch (_) {
      throw const QoderAccountError('invalid_storage');
    }
  }

  Future<void> _save(_Store s, {String? nonce}) async {
    final out =
        await _nativeCall(nonce == null ? 'compareAndSet' : 'commitGrant', {
          'expectedRevision': s.revision,
          'payload': jsonEncode(s.data),
          if (nonce != null) 'nonce': nonce,
        });
    if (out['revision'] != s.revision + 1)
      throw const QoderAccountError('storage_unavailable');
    s.revision++;
  }

  /// Must be invoked only for the user's explicit sign-in action. Saving the
  /// resulting persistent grant requires the host's action-time confirmation.
  Future<QoderLogin> startLogin() async {
    if (_closed || _claiming || _starting || _grant != null)
      throw const QoderAccountError('login_busy');
    _starting = true;
    final epoch = _cancelEpoch;
    try {
      final now = _now();
      if (now < 0) throw const QoderAccountError('clock_invalid');
      final store = await _read();
      if (epoch != _cancelEpoch) throw const QoderAccountError('cancelled');
      final m = await _nativeCall('newGrant', {});
      if (epoch != _cancelEpoch) {
        await _nativeCall('cancelGrant', {'nonce': m['nonce']});
        throw const QoderAccountError('cancelled');
      }
      if (!RegExp(
            r'^[A-Za-z0-9_-]{43}$',
          ).hasMatch(m['verifier'] is String ? m['verifier'] : '') ||
          !RegExp(
            r'^[A-Za-z0-9_-]{43}$',
          ).hasMatch(m['challenge'] is String ? m['challenge'] : '') ||
          !_uuid(m['nonce']) ||
          !_uuid(m['machineId']))
        throw const QoderAccountError('invalid_grant');
      _commitNonce = null;
      _commitOutcome = null;
      _grant = _Grant(m, now + 300000, store);
      return QoderLogin(
        Uri.https(region.authHost, '/device/selectAccounts', {
          'challenge': m['challenge'],
          'challenge_method': 'S256',
          'nonce': m['nonce'],
          'machine_id': m['machineId'],
          'client_id': region.clientId,
        }),
      );
    } finally {
      _starting = false;
    }
  }

  Future<String> cancelLogin() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _cancelEpoch++;
    final g = _grant;
    _grant = null;
    if (g == null && _commitOutcome != null) return _commitOutcome!;
    final nonce = g?.material['nonce'] ?? _commitNonce;
    if (nonce == null) return 'cancelled';
    try {
      final r = await _nativeCall('cancelGrant', {'nonce': nonce});
      final outcome = r['status'] == 'completed'
          ? 'completed'
          : r['status'] == 'cancelled'
          ? 'cancelled'
          : 'unknown';
      if (nonce == _commitNonce) _commitOutcome = outcome;
      return outcome;
    } on QoderAccountError {
      return 'unknown';
    }
  }

  Future<String?> pollLogin() async {
    final g = _grant;
    if (g == null) throw const QoderAccountError('login_required');
    final now = _now();
    if (now < 0 || now >= (g.authorized?['_expiresAt'] ?? g.expires)) {
      _grant = null;
      throw const QoderAccountError('expired');
    }
    if (g.polling || g.lastPoll != null && now - g.lastPoll! < 1000)
      return null;
    g.polling = true;
    try {
      g.lastPoll = _now();
      final result = g.authorized != null
          ? QoderResponse(200, g.authorized!)
          : await _http.send(
              'GET',
              _url('/api/v1/deviceToken/poll', {
                'nonce': g.material['nonce'],
                'verifier': g.material['verifier'],
                'challenge_method': 'S256',
              }),
              null,
              null,
            );
      _checkGrant(g);
      if (result.status == 404) {
        g.lastPoll = _now();
        return null;
      }
      if (result.status != 200)
        throw const QoderAccountError('authentication_required');
      final b = result.body;
      final token = b['device_token'] ?? b['token'],
          refresh = b['refresh_token'] ?? '';
      final uid = _uid(b['user_id']);
      if (!_text(token) ||
          refresh is! String ||
          refresh.isNotEmpty && !_text(refresh))
        throw const QoderAccountError('invalid_response');
      int expiry;
      if (b['expires_at'] is String) {
        final value = b['expires_at'] as String;
        if (!RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(value))
          throw const QoderAccountError('invalid_response');
        expiry = DateTime.parse(value).millisecondsSinceEpoch;
      } else if (b['expires_at'] == null &&
          b['expires_in'] is int &&
          b['expires_in'] > 0) {
        expiry = _now() + (b['expires_in'] as int) * 1000;
      } else {
        throw const QoderAccountError('invalid_response');
      }
      if (g.authorized != null) expiry = g.authorized!['_expiresAt'];
      if (expiry <= _now()) throw const QoderAccountError('expired');
      g.authorized = {...b, '_expiresAt': expiry};
      final user = await _http.send(
        'GET',
        _url('/api/v1/userinfo'),
        token,
        null,
      );
      _checkGrant(g);
      if (user.status != 200 ||
          _uid(user.body['id'] ?? user.body['user_id'] ?? user.body['uid']) !=
              uid)
        throw const QoderAccountError('identity_mismatch');
      final store = g.store;
      _checkGrant(g);
      // The same UID keeps its durable claim history, including uncertain sends.
      store.data['accounts'][uid] = {
        'token': token,
        'refreshToken': refresh,
        'expiresAt': expiry,
        'refreshExpiresAt': _expiry(b, 'refresh_token', optional: true),
        'machineId': g.material['machineId'],
        'generation': g.material['nonce'],
        'registrationId':
            store.data['accounts'][uid]?['registrationId'] ??
            newAccountRegistrationId(),
        'label': _label(user.body, uid),
        'automatic': true,
      };
      // An uncertain native commit is reconciled by reading the saved accounts;
      // never poll a consumed grant again or blindly report cancellation.
      _commitNonce = g.material['nonce'];
      _commitOutcome = 'unknown';
      await _save(store, nonce: _commitNonce);
      _commitOutcome = 'completed';
      _verified[uid] = g.material['nonce'];
      _rotations.remove(uid);
      if (!_closed) _authorizationChanges.add(null);
      if (identical(_grant, g)) _grant = null;
      return uid;
    } on QoderAccountError catch (e) {
      if (!{'network_error', 'http_error', 'rate_limited'}.contains(e.code) &&
          identical(_grant, g))
        _grant = null;
      rethrow;
    } catch (_) {
      if (identical(_grant, g)) _grant = null;
      throw const QoderAccountError('invalid_response');
    } finally {
      g.polling = false;
    }
  }

  void _checkGrant(_Grant g) {
    if (_closed || !identical(_grant, g))
      throw const QoderAccountError('cancelled');
    if (_now() < 0 || _now() >= (g.authorized?['_expiresAt'] ?? g.expires))
      throw const QoderAccountError('expired');
  }

  static String _label(Map<String, dynamic> user, String uid) {
    for (final key in ['name', 'nickname', 'nick_name', 'email']) {
      final value = user[key];
      if (_text(value, max: 160)) return value as String;
    }
    return uid;
  }

  static String _uid(Object? v) {
    final value = v is num && v.isFinite ? v.toString() : v;
    if (!_text(value, max: 1024))
      throw const QoderAccountError('invalid_response');
    return value as String;
  }

  Future<List<String>> accounts() async => List<String>.unmodifiable(
    (await _read()).data['accounts'].keys.cast<String>(),
  );
  int? _expiry(
    Map<String, dynamic> data,
    String prefix, {
    bool optional = false,
  }) {
    final name = prefix.isEmpty ? 'expires' : '${prefix}_expires';
    final at = data['${name}_at'], seconds = data['${name}_in'];
    if (at is String && RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(at)) {
      final date = DateTime.tryParse(at);
      if (date != null) return date.millisecondsSinceEpoch;
    }
    if (at == null && seconds is int && seconds > 0 && seconds <= 315360000)
      return _now() + seconds * 1000;
    if (optional && at == null && seconds == null) return null;
    throw const QoderAccountError('invalid_response');
  }

  final _rotations = <String, (String, Map<String, dynamic>)>{};

  /// Persist only a definite refusal of the exact token/local grant dispatched.
  /// A replacement saved since that request began is never invalidated.
  Future<void> rejectInferenceAuthorization(
    String uid,
    String registration,
    String expectedToken,
  ) async {
    if (_closed) return;
    bool same(Map? a) =>
        a != null &&
        a['token'] == expectedToken &&
        a['registrationId'] == registration;
    String? generation;
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        final store = await _read();
        final a = store.data['accounts'][uid] as Map<String, dynamic>?;
        if (_closed || !same(a)) return;
        generation = a!['generation'];
        if (a['accessRejected'] == true) return;
        a['accessRejected'] = true;
        if (a['refusalRecoveryAttempted'] == true ||
            a['refreshToken'] == '' ||
            a['refreshExpiresAt'] is int && a['refreshExpiresAt'] <= _now())
          a['authorizationInvalid'] = true;
        try {
          await _save(store);
          return;
        } on QoderAccountError {
          final saved = (await _read()).data['accounts'][uid] as Map?;
          if (!same(saved) || saved!['accessRejected'] == true) return;
        }
      }
      throw const QoderAccountError('storage_unavailable');
    } catch (_) {
      if (generation != null) _blockedAuthorizations[uid] = generation;
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _authorized(_Store s, String uid) async {
    var a = s.data['accounts'][uid] as Map<String, dynamic>?;
    if (a == null) throw const QoderAccountError('identity_required');
    if (a['authorizationInvalid'] == true)
      throw const QoderAccountError('identity_expired');
    if (_blockedAuthorizations[uid] == a['generation'])
      throw const QoderAccountError('authorization_temporarily_unavailable');
    var pending = _rotations[uid];
    if (pending != null &&
        a['generation'] == pending.$2['generation'] &&
        a['token'] == pending.$2['token']) {
      _rotations.remove(uid);
      pending = null;
    }
    if (pending != null && a['generation'] != pending.$1) {
      // Another owner saved a different grant while this refresh completed.
      // Its CAS winner is authoritative; never overwrite it with our result.
      _rotations.remove(uid);
      pending = null;
    }
    if (pending == null && a['refreshPending'] == true)
      throw const QoderAccountError('authorization_temporarily_unavailable');
    final forced = a['accessRejected'] == true;
    if (pending == null && (forced || a['expiresAt'] < _now() + 300000)) {
      if (forced && a['refusalRecoveryAttempted'] == true ||
          a['refreshToken'] == '' ||
          a['refreshExpiresAt'] is int && a['refreshExpiresAt'] <= _now()) {
        if (forced || a['expiresAt'] <= _now())
          throw const QoderAccountError('identity_expired');
      } else {
        // Reservation is durable before the one refresh transmission. A lost
        // reply leaves this pending across restart; the grant is never replayed.
        a = {
          ...a,
          'refreshPending': true,
          if (forced) 'refusalRecoveryAttempted': true,
        };
        s.data['accounts'][uid] = a;
        await _save(s);
        if (_closed) throw const QoderAccountError('closed');
        final response = await _http.send(
          'POST',
          _url('/api/v1/deviceToken/refresh'),
          null,
          {'refresh_token': a['refreshToken']},
          isCurrent: () => !_closed,
        );
        if ({401, 403}.contains(response.status)) {
          a.remove('refreshPending');
          a['authorizationInvalid'] = true;
          await _save(s);
          throw const QoderAccountError('identity_expired');
        }
        if (response.status != 200) {
          if (response.status != 400)
            throw const QoderAccountError(
              'authorization_temporarily_unavailable',
            );
          // A definite temporary400 issued no replacement. A still-valid,
          // unrefused old access token remains usable; a refused one does not.
          a.remove('refreshPending');
          if (forced) a['authorizationInvalid'] = true;
          await _save(s);
          if (forced) throw const QoderAccountError('identity_expired');
          if (a['expiresAt'] <= _now())
            throw const QoderAccountError(
              'authorization_temporarily_unavailable',
            );
        } else {
          final b = response.body,
              token = response.body['device_token'] ?? response.body['token'];
          if (!_text(token) || !_text(b['refresh_token']))
            throw const QoderAccountError('invalid_response');
          final expiry = _expiry(b, '')!;
          if (expiry <= _now())
            throw const QoderAccountError('invalid_response');
          final bytes = List.generate(16, (_) => Random.secure().nextInt(256));
          bytes[6] = (bytes[6] & 15) | 64;
          bytes[8] = (bytes[8] & 63) | 128;
          final hex = bytes
              .map((v) => v.toRadixString(16).padLeft(2, '0'))
              .join();
          final generation =
              '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
          pending = (
            a['generation'] as String,
            {
              ...a,
              'refreshPending': false,
              'accessRejected': false,
              'refusalRecoveryAttempted': forced,
              'token': token,
              'refreshToken': b['refresh_token'],
              'expiresAt': expiry,
              'refreshExpiresAt':
                  _expiry(b, 'refresh_token', optional: true) ??
                  a['refreshExpiresAt'],
              'generation': generation,
            },
          );
          _rotations[uid] = pending;
        }
      }
    }
    if (pending != null) {
      if (a['generation'] != pending.$1)
        throw const QoderAccountError('source_changed');
      a = pending.$2;
      s.data['accounts'][uid] = a;
      // Persist rotation before any fallible identity lookup, including on quit.
      await _save(s);
      _rotations.remove(uid);
    }
    if (_closed) throw const QoderAccountError('closed');
    if (a['accessRejected'] == true || a['refreshPending'] == true)
      throw const QoderAccountError('identity_expired');
    if (_now() < 0 || a['expiresAt'] <= _now())
      throw const QoderAccountError('identity_expired');
    if (_verified[uid] != a['generation']) {
      final profile = await _http.send(
        'GET',
        _url('/api/v1/userinfo'),
        a['token'],
        null,
      );
      if (profile.status != 200 ||
          _uid(
                profile.body['id'] ??
                    profile.body['user_id'] ??
                    profile.body['uid'],
              ) !=
              uid)
        throw const QoderAccountError('identity_mismatch');
      if (_closed) throw const QoderAccountError('closed');
      _verified[uid] = a['generation'];
    }
    return a;
  }

  Future<T> withInferenceAuthorization<T>(
    String uid,
    Future<T> Function(
      String token,
      String machineId,
      String registrationId,
      bool Function() isCurrent,
    )
    use, {
    String? expectedRegistrationId,
  }) async {
    if (_closed || _claiming || _grant != null)
      throw const QoderAccountError('busy');
    _claiming = true;
    var active = true;
    try {
      final store = await _read();
      if (expectedRegistrationId != null &&
          store.data['accounts'][uid]?['registrationId'] !=
              expectedRegistrationId)
        throw const QoderAccountError('source_changed');
      final account = await _authorized(store, uid);
      if (account['registrationId'] == null) {
        account['registrationId'] = newAccountRegistrationId();
        await _save(store);
      }
      final registration = account['registrationId'] as String;
      if (expectedRegistrationId != null &&
          registration != expectedRegistrationId)
        throw const QoderAccountError('source_changed');
      return await use(
        account['token'],
        account['machineId'],
        registration,
        () => active && !_closed && account['expiresAt'] > _now(),
      );
    } finally {
      active = false;
      _claiming = false;
    }
  }

  final _credits = <String, QoderCredits>{};
  QoderCredits? credits(String uid) => _credits[uid];
  Future<void> refreshCredits(String uid) async {
    if (_closed || _claiming || _grant != null)
      throw const QoderAccountError('busy');
    _claiming = true;
    try {
      _credits.remove(uid);
      final store = await _read();
      final a = await _authorized(store, uid);
      final response = await _http.send(
        'GET',
        _url('/sash/api/v2/me/usage'),
        a['token'],
        null,
      );
      if (response.status != 200) throw const QoderAccountError('http_error');
      _envelope(response.body, uid);
      final current = await _read();
      if (_closed ||
          current.data['accounts'][uid]?['generation'] != a['generation'])
        throw const QoderAccountError('source_changed');
      _credits[uid] = normalizeQoderCredits(
        response.body,
        DateTime.fromMillisecondsSinceEpoch(_now(), isUtc: true),
      );
    } on QoderAccountError {
      rethrow;
    } catch (_) {
      throw const QoderAccountError('invalid_response');
    } finally {
      _claiming = false;
    }
  }

  static void _envelope(Map b, String uid, {bool receipt = false}) {
    final nested = b['data'];
    if (nested is Map) {
      for (final k in ['code', 'status']) {
        if (nested.containsKey(k) &&
            ![
              '0',
              '200',
              'SUCCESS',
              'OK',
              if (receipt && k == 'status') 'CLAIMED',
            ].contains(nested[k].toString()))
          throw const QoderAccountError('verification_required');
      }
    }
    if (b.containsKey('uid') && b['uid'] != uid)
      throw const QoderAccountError('identity_mismatch');
    if (b.containsKey('success') && b['success'] != true || b['error'] != null)
      throw const QoderAccountError('service_rejected');
    for (final k in ['code', 'status']) {
      if (b.containsKey(k) &&
          ![
            '0',
            '200',
            'SUCCESS',
            'OK',
            if (receipt && k == 'status') 'CLAIMED',
          ].contains(b[k].toString()))
        throw const QoderAccountError('verification_required');
    }
  }

  static String? _skip(Map r, Set<String> duplicate) {
    final benefit = r['benefit'];
    if (benefit is! Map ||
        benefit['kind'] != 'CREDITS' ||
        benefit['amount'] is! num ||
        !(benefit['amount'] as num).isFinite ||
        benefit['amount'] <= 0)
      return 'unsupported_benefit';
    final id = r['campaignId'];
    if (!_text(id, max: 256) ||
        id == '.' ||
        id == '..' ||
        (id as String).contains(RegExp(r'[\u202a-\u202e\u2066-\u2069]')))
      return 'invalid_activity';
    if (r['campaignKey'] != null && !_text(r['campaignKey'], max: 256))
      return 'invalid_activity';
    if (duplicate.contains(id)) return 'ambiguous_campaign';
    if (r['actionType'] != 'CLAIM_BENEFIT') return 'unsupported_action';
    if (r['unavailableReason'] != null && r['unavailableReason'] != '')
      return 'unavailable';
    if (r['requiredAchievementKey'] != null &&
        r['requiredAchievementKey'] != '' &&
        r['achievementCompleted'] != true)
      return 'achievement_required';
    if ([
          'purchaseRequired',
          'subscriptionRequired',
          'termsAcceptanceRequired',
        ].any((k) => r[k] != null && r[k] != false) ||
        r['creditsCost'] != null && r['creditsCost'] != 0)
      return 'additional_condition';
    for (final k in ['startAt', 'endAt']) {
      if (r[k] != null && (r[k] is! int || r[k] < 0 || r[k] > 253402300799))
        return 'invalid_activity';
    }
    if (r['startAt'] != null &&
        r['endAt'] != null &&
        r['startAt'] >= r['endAt'])
      return 'invalid_activity';
    return null;
  }

  /// Explicit free-benefit action for one independently authorized regional account.
  Future<List<Map<String, dynamic>>> claim(String uid) async {
    if (_closed || _claiming || _grant != null)
      throw const QoderAccountError('claim_busy');
    _claiming = true;
    try {
      final s = await _read();
      final a = await _authorized(s, uid);
      final listing = await _http.send(
        'GET',
        _url('/sash/api/v1/me/campaigns'),
        a['token'],
        null,
      );
      final elapsed = Stopwatch()..start();
      if (listing.status != 200) throw const QoderAccountError('http_error');
      _envelope(listing.body, uid);
      final rows = listing.body['campaigns'];
      if (rows is! List || rows.length > 100)
        throw const QoderAccountError('invalid_response');
      final counts = <String, int>{};
      for (final r in rows) {
        if (r is Map && r['campaignId'] is String)
          counts[r['campaignId']] = (counts[r['campaignId']] ?? 0) + 1;
      }
      final dup = counts.keys.where((k) => counts[k]! > 1).toSet(),
          out = <Map<String, dynamic>>[];
      for (final raw in rows) {
        if (raw is! Map) {
          out.add({
            'campaignId': '',
            'outcome': 'skipped',
            'reason': 'invalid_activity',
          });
          continue;
        }
        final r = raw;
        final id = r['campaignId'];
        String? skip = _skip(r, dup);
        if (r['uid'] != null && r['uid'] != uid) skip = 'identity_mismatch';
        final server = listing.serverMs == null
            ? null
            : listing.serverMs! + elapsed.elapsedMilliseconds;
        if (r['startAt'] != null || r['endAt'] != null) {
          if (server == null)
            skip = 'server_time_required';
          else if (r['startAt'] is int && server < r['startAt'] * 1000)
            skip = 'not_started';
          else if (r['endAt'] is int && server >= r['endAt'] * 1000)
            skip = 'ended';
        }
        final key = jsonEncode([uid, id]);
        final old = s.data['claims'][key];
        final target = {
          for (final k in ['campaignId', 'campaignKey', 'startAt', 'endAt'])
            k: r[k],
        };
        if (old != null) {
          final same =
              old['target'] is Map &&
              [
                'campaignId',
                'campaignKey',
                'startAt',
                'endAt',
              ].every((k) => old['target'][k] == target[k]);
          if (old['state'] == 'pending' || old['state'] == 'unknown') {
            if (same && skip == null && r['claimStatus'] == 'CLAIMED') {
              old['state'] = 'reconciled';
              await _save(s);
              out.add({
                'campaignId': id,
                'outcome': 'observedClaimed',
                'reason': 'reconciled_no_new_round',
              });
            } else {
              out.add({
                'campaignId': id,
                'outcome': 'unknown',
                'reason': 'existing_attempt',
              });
            }
            continue;
          }
          if (same && skip == null && r['claimStatus'] == 'CLAIMED') {
            if (old['state'] == 'claimed') {
              old['listingClaimed'] = true;
              await _save(s);
            }
            out.add({'campaignId': id, 'outcome': 'observedClaimed'});
            continue;
          }
          final before = old['target'];
          final advanced =
              before is Map &&
              before['startAt'] is int &&
              before['endAt'] is int &&
              r['startAt'] is int &&
              r['endAt'] is int &&
              r['startAt'] >= before['endAt'];
          final observedRearm =
              same &&
              old['state'] == 'claimed' &&
              old['listingClaimed'] == true;
          if (!advanced && !observedRearm) {
            out.add({
              'campaignId': id,
              'outcome': 'skipped',
              'reason': 'same_campaign_no_new_window',
            });
            continue;
          }
        }
        if (skip != null || r['claimStatus'] != 'CLAIMABLE') {
          out.add({
            'campaignId': id is String ? id : '',
            'outcome': r['claimStatus'] == 'CLAIMED'
                ? 'observedClaimed'
                : 'skipped',
            'reason': skip ?? 'not_claimable',
          });
          continue;
        }
        if (_closed) throw const QoderAccountError('closed');
        if (a['expiresAt'] <= _now())
          throw const QoderAccountError('identity_expired');
        s.data['claims'][key] = {
          'state': 'pending',
          'target': target,
          'generation': a['generation'],
          'listingClaimed': false,
          if (old?['state'] == 'claimed')
            'previousSuccess': {'confirmedAtMs': old['confirmedAtMs']}
          else if (old?['previousSuccess'] is Map)
            'previousSuccess': old['previousSuccess'],
        };
        await _save(s); // Durable CAS BEFORE POST.
        final current = await _read();
        if (_closed) throw const QoderAccountError('closed');
        if (current.revision != s.revision ||
            current.data['accounts'][uid]?['generation'] != a['generation'])
          throw const QoderAccountError('source_changed');
        if (_now() < 0 || a['expiresAt'] <= _now())
          throw const QoderAccountError('identity_expired');
        final dispatchServer = listing.serverMs == null
            ? null
            : listing.serverMs! + elapsed.elapsedMilliseconds;
        if (r['startAt'] != null || r['endAt'] != null) {
          if (dispatchServer == null ||
              r['startAt'] is int && dispatchServer < r['startAt'] * 1000 ||
              r['endAt'] is int && dispatchServer >= r['endAt'] * 1000)
            throw const QoderAccountError('campaign_window_changed');
        }

        String outcome = 'unknown';
        bool admitted() {
          if (_closed || _now() < 0 || a['expiresAt'] <= _now()) return false;
          final serverNow = listing.serverMs == null
              ? null
              : listing.serverMs! + elapsed.elapsedMilliseconds;
          return (r['startAt'] == null ||
                  serverNow != null && serverNow >= r['startAt'] * 1000) &&
              (r['endAt'] == null ||
                  serverNow != null && serverNow < r['endAt'] * 1000);
        }

        try {
          final response = await _http.send(
            'POST',
            Uri(
              scheme: 'https',
              host: region.apiHost,
              pathSegments: [
                'sash',
                'api',
                'v1',
                'me',
                'campaigns',
                id,
                'claim',
              ],
            ),
            a['token'],
            null,
            isCurrent: admitted,
          );
          if (response.status != 200)
            throw const QoderAccountError('http_error');
          _envelope(response.body, uid, receipt: true);
          final data = response.body['data'];
          if (data != null && data is! Map)
            throw const QoderAccountError('invalid_response');
          for (final b in [response.body, if (data is Map) data]) {
            _envelope(b, uid, receipt: true);
            for (final k in ['campaignId', 'campaignKey', 'startAt', 'endAt']) {
              if (b[k] != null && r[k] != null && b[k] != r[k])
                throw const QoderAccountError('invalid_response');
            }
          }
          if (response.body['status'] == 'CLAIMED' ||
              data is Map && data['status'] == 'CLAIMED')
            outcome = 'claimedDeltaUnknown';
        } catch (_) {
          /* Never leak token-bearing transport errors or retry a POST. */
        }
        s.data['claims'][key]['state'] = outcome == 'unknown'
            ? 'unknown'
            : 'claimed';
        if (outcome == 'claimedDeltaUnknown') {
          s.data['claims'][key]['confirmedAtMs'] = _now();
          (s.data['claims'][key] as Map).remove('previousSuccess');
        }
        await _save(s);
        out.add({'campaignId': id, 'outcome': outcome});
      }
      a['lastOutcome'] = out.any((r) => r['outcome'] == 'unknown')
          ? 'unknown'
          : out.any((r) => r['outcome'] == 'claimedDeltaUnknown')
          ? 'claimedDeltaUnknown'
          : out.any((r) => r['outcome'] == 'observedClaimed')
          ? 'observedClaimed'
          : 'unavailable';
      await _save(s);
      return List.unmodifiable(out);
    } on QoderAccountError {
      rethrow;
    } catch (_) {
      throw const QoderAccountError('request_failed');
    } finally {
      _claiming = false;
    }
  }
}
