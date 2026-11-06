import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'account_document_store.dart';
import 'credit_summary.dart';
import 'trae_credits.dart';
import 'trae_http.dart';
import 'trae_oauth.dart';

typedef TraeProof =
    Future<Map<String, dynamic>> Function(
      String privateKey,
      String refreshToken,
    );

class TraeAccount {
  final String uid, label, outcome, authorizationOwner;
  final bool automatic;
  final num? credited;
  TraeAccount(Map<String, dynamic> value)
    : uid = value['uid'],
      label = value['label'],
      outcome = value['outcome'] ?? 'unavailable',
      automatic = value['automatic'] == true,
      authorizationOwner = value['owner'],
      credited = value['credited'];
}

/// Owns authorization, persistence, refresh and scheduling. Widgets only issue
/// explicit actions or read redacted account views.
class TraeAccounts {
  final AccountDocumentStore store;
  final TraeTransport http;
  final TraeProof proof;
  final int Function() now;
  FutureOr<void> Function()? onChanged;
  bool _busy = false, _closed = false, _ticking = false;
  Timer? _startup, _automatic, _loginTimer;
  TraeOAuth? _login;
  Map<String, dynamic>? _pendingImport;
  final _credits = <String, CreditSummary>{};
  final _verified = <String, String>{};
  final _rotations = <String, (String, Map<String, dynamic>)>{};
  String? message;
  TraeAccounts({
    required this.store,
    required this.http,
    required this.proof,
    int Function()? now,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);
  bool get loginPending => _login != null;
  bool get importPending => _pendingImport != null;
  CreditSummary? credits(String uid) => _credits[uid];
  void _alive() {
    if (_closed) throw const TraeFailure('closed');
  }

  String _generation() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  Future<AccountDocument> _read() async {
    try {
      final snapshot = await store.read(), data = snapshot.data;
      if (data.isEmpty)
        data.addAll({'version': 1, 'accounts': <String, dynamic>{}});
      if (data['version'] != 1 || data['accounts'] is! Map<String, dynamic>)
        throw const TraeFailure('invalid_storage');
      for (final e in (data['accounts'] as Map<String, dynamic>).entries) {
        final a = e.value;
        if (a is! Map<String, dynamic> ||
            a['uid'] != e.key ||
            a['label'] is! String ||
            !TraeOAuthToken.text(a['token']) ||
            a['expiresAt'] is! int ||
            a['generation'] is! String ||
            !{'loongpass', 'officialClient'}.contains(a['owner']) ||
            a['claims'] is! Map<String, dynamic> ||
            a['device'] is! Map<String, dynamic> ||
            a['automatic'] is! bool)
          throw const TraeFailure('invalid_storage');
      }
      return snapshot;
    } on TraeFailure {
      rethrow;
    } catch (_) {
      throw const TraeFailure('storage_unavailable');
    }
  }

  Future<void> _write(AccountDocument doc) async {
    try {
      await store.write(doc.revision, doc.data);
    } catch (_) {
      throw const TraeFailure('storage_unavailable');
    }
  }

  Future<List<TraeAccount>> accounts() async => [
    for (final a in ((await _read()).data['accounts'] as Map).values)
      TraeAccount(a),
  ];
  Future<void> _notify() async {
    if (!_closed) {
      try {
        await onChanged?.call();
      } catch (_) {}
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    _alive();
    if (_busy) throw const TraeFailure('busy');
    _busy = true;
    try {
      return await action();
    } finally {
      _busy = false;
      await _notify();
    }
  }

  static void _validReply(TraeReply reply) {
    if (reply.status == 401 || reply.status == 403)
      throw const TraeFailure('authorization_required');
    if (reply.status != 200) throw const TraeFailure('network_unavailable');
    if (reply.body['ResponseMetadata'] case {'Error': final Object _})
      throw const TraeFailure('service_rejected');
    if (reply.body.containsKey('code') && reply.body['code'] != 0)
      throw const TraeFailure('service_rejected');
  }

  Future<Map<String, dynamic>> _profile(
    String token,
    Map<String, dynamic> device,
  ) async {
    final reply = await http.post(
      TraeHttp.profile,
      {'ReqSource': 'IDE', 'IDEVersion': device['ClientVersion']},
      token: token,
      isCurrent: () => !_closed,
    );
    _alive();
    _validReply(reply);
    final result = reply.body['Result'];
    if (result is! Map<String, dynamic> ||
        result['UserID'] is! String ||
        (result['UserID'] as String).isEmpty)
      throw const TraeFailure('invalid_identity');
    return result;
  }

  static Map<String, dynamic> _context(Map<String, dynamic> source) {
    final device = source['device'], key = source['privateKeyPEM'];
    if (device is! Map<String, dynamic> ||
        key is! String ||
        key.isEmpty ||
        key.length > 16384)
      throw const TraeFailure('invalid_device');
    for (final field in [
      'DeviceID',
      'MachineID',
      'ClientVersion',
      'DevicePublicKey',
    ]) {
      if (device[field] is! String || (device[field] as String).isEmpty)
        throw const TraeFailure('invalid_device');
    }
    if (device['PlatformCode'] != 'IDE_PC' || device['DeviceType'] != 'PC')
      throw const TraeFailure('invalid_device');
    return {'device': device, 'privateKeyPEM': key};
  }

  Future<void> importCurrent([Map<String, dynamic>? source]) =>
      _exclusive(() async {
        if (loginPending) throw const TraeFailure('busy');
        if (source != null) _pendingImport = jsonDecode(jsonEncode(source));
        try {
          final pending = _pendingImport;
          if (pending == null) throw const TraeFailure('source_required');
          final context = _context(pending), a = pending['account'];
          if (a is! Map ||
              !TraeOAuthToken.text(a['token']) ||
              a['uid'] is! String ||
              a['expiresAt'] is! int)
            throw const TraeFailure('invalid_source');
          if (a['expiresAt'] <= now())
            throw const TraeFailure('authorization_expired');
          final profile = await _profile(a['token'], context['device']);
          if (profile['UserID'] != a['uid'])
            throw const TraeFailure('identity_mismatch');
          await _saveAccount(profile, context, {
            'token': a['token'],
            'expiresAt': a['expiresAt'],
            'owner': 'officialClient',
          });
          _pendingImport = null;
          message = '已核实并保存 TRAE CN 当前账号，自动签到已开启。';
          startAutomatic();
        } on TraeFailure catch (error) {
          if ({
            'invalid_device',
            'invalid_source',
            'authorization_expired',
            'identity_mismatch',
          }.contains(error.code)) {
            _pendingImport = null;
          }
          rethrow;
        }
      });
  Future<void> _saveAccount(
    Map<String, dynamic> profile,
    Map<String, dynamic> context,
    Map<String, dynamic> grant,
  ) async {
    _alive();
    final doc = await _read(), uid = profile['UserID'] as String;
    final old = doc.data['accounts'][uid] as Map?;
    final label = profile['ScreenName'] ?? profile['NonPlainTextEmail'] ?? uid;
    final a = <String, dynamic>{
      ...grant,
      ...context,
      'uid': uid,
      'label': label is String && label.isNotEmpty
          ? String.fromCharCodes(label.runes.take(160))
          : uid,
      'generation': _generation(),
      'automatic': true,
      'claims': old?['claims'] ?? <String, dynamic>{},
      'outcome': old?['outcome'] ?? 'unavailable',
      'credited': old?['credited'],
    };
    doc.data['context'] = context;
    doc.data['accounts'][uid] = a;
    await _write(doc);
    _verified[uid] = a['generation'];
    _rotations.remove(uid);
  }

  Future<Uri> beginAuthorization() => _exclusive(() async {
    if (_login != null) throw const TraeFailure('busy');
    final context = (await _read()).data['context'];
    if (context is! Map<String, dynamic>)
      throw const TraeFailure('device_required');
    _context(context);
    final login = TraeOAuth(http: http, device: context['device'], now: now);
    _login = login;
    try {
      return await login.begin();
    } catch (_) {
      login.cancel();
      _login = null;
      rethrow;
    }
  });
  void followAuthorization() {
    _loginTimer?.cancel();
    _loginTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_closed || _busy) return;
      try {
        await finishAuthorization();
      } on TraeFailure catch (e) {
        message = '授权未完成（${e.code}），已有结果会保留重试。';
        await _notify();
      }
    });
  }

  Future<void> finishAuthorization() => _exclusive(() async {
    final login = _login;
    if (login == null) return;
    if (!login.active) {
      cancelAuthorization();
      throw const TraeFailure('authorization_ended');
    }
    final token = await login.poll();
    if (token == null) return;
    final context = (await _read()).data['context'] as Map<String, dynamic>;
    final profile = await _profile(token.accessToken, context['device']);
    if (!identical(login, _login)) throw const TraeFailure('cancelled');
    await _saveAccount(profile, context, {
      'token': token.accessToken,
      'refreshToken': token.refreshToken,
      'expiresAt': token.expiresAt,
      'refreshExpiresAt': token.refreshExpiresAt,
      'owner': 'loongpass',
    });
    cancelAuthorization();
    message = '账号已验证并保存，自动签到已开启。';
    startAutomatic();
  });
  void cancelAuthorization() {
    _loginTimer?.cancel();
    _loginTimer = null;
    _login?.cancel();
    _login = null;
  }

  Future<Map<String, dynamic>> _authorized(String uid) async {
    var doc = await _read();
    var a = doc.data['accounts'][uid] as Map<String, dynamic>?;
    if (a == null) throw const TraeFailure('account_missing');
    var pending = _rotations[uid];
    if (pending != null &&
        a['generation'] == pending.$2['generation'] &&
        a['token'] == pending.$2['token']) {
      _rotations.remove(uid);
      pending = null;
    }
    if (pending == null &&
        a['owner'] == 'loongpass' &&
        a['expiresAt'] <= now() + 60000) {
      if (a['refreshExpiresAt'] is! int || a['refreshExpiresAt'] <= now())
        throw const TraeFailure('authorization_expired');
      final deviceProof = await proof(a['privateKeyPEM'], a['refreshToken']);
      final reply = await http.post(
        TraeHttp.exchange,
        {
          'ClientID': 'ono9krqynydwx5',
          'ClientSecret': '',
          'RefreshToken': a['refreshToken'],
          'DeviceInfo': a['device'],
          'DeviceProof': deviceProof,
          'IDEVersion': a['device']['ClientVersion'],
        },
        token: a['token'],
        isCurrent: () => !_closed,
      );
      _validReply(reply);
      final result = reply.body['Result'];
      if (result is! Map<String, dynamic>)
        throw const TraeFailure('invalid_token');
      final token = TraeOAuthToken.parse(result, now());
      pending = (
        a['generation'] as String,
        {
          ...a,
          'token': token.accessToken,
          'refreshToken': token.refreshToken,
          'expiresAt': token.expiresAt,
          'refreshExpiresAt': token.refreshExpiresAt,
          'generation': _generation(),
        },
      );
      _rotations[uid] = pending;
    }
    if (pending != null) {
      doc = await _read();
      if (doc.data['accounts'][uid]?['generation'] != pending.$1)
        throw const TraeFailure('source_changed');
      a = pending.$2;
      doc.data['accounts'][uid] = a;
      await _write(doc);
      _rotations.remove(uid); // Before fallible profile request.
    }
    _alive();
    if (a['expiresAt'] <= now())
      throw const TraeFailure('authorization_expired');
    if (_verified[uid] != a['generation']) {
      final profile = await _profile(a['token'], a['device']);
      if (profile['UserID'] != uid)
        throw const TraeFailure('identity_mismatch');
      _verified[uid] = a['generation'];
    }
    return a;
  }

  Future<CreditSummary> _readCredits(Map<String, dynamic> a) async {
    final reply = await http.post(
      TraeHttp.credits,
      {'require_usage': true, 'req_source': 1},
      token: a['token'],
      device: a['device'],
      isCurrent: () => !_closed && a['expiresAt'] > now(),
    );
    _alive();
    _validReply(reply);
    try {
      return normalizeTraeCredits(
        reply.body,
        DateTime.fromMillisecondsSinceEpoch(now(), isUtc: true),
      );
    } catch (_) {
      throw const TraeFailure('invalid_credits');
    }
  }

  Future<void> refreshCredits(String uid) => _exclusive(() async {
    final a = await _authorized(uid);
    _credits[uid] = await _readCredits(a);
  });
  static String _day(int ms) => DateTime.fromMillisecondsSinceEpoch(
    ms,
    isUtc: true,
  ).add(const Duration(hours: 8)).toIso8601String().substring(0, 10);
  Future<TraeReply> _status(Map<String, dynamic> a) async {
    final reply = await http.post(
      TraeHttp.status,
      {'req_source': 1},
      token: a['token'],
      device: a['device'],
      isCurrent: () => !_closed && a['expiresAt'] > now(),
    );
    _alive();
    _validReply(reply);
    if (reply.body['enable'] is! bool ||
        reply.body['checked_in'] is! bool ||
        reply.body['did_checked_in'] != null &&
            reply.body['did_checked_in'] is! bool)
      throw const TraeFailure('invalid_status');
    return reply;
  }

  Future<void> claim(String uid) => _exclusive(() async {
    final a = await _authorized(uid);
    final status = await _status(a);
    final elapsed = Stopwatch()..start();
    if (status.serverMs == null)
      throw const TraeFailure('server_time_required');
    final day = _day(status.serverMs!), b = status.body;
    final doc = await _read(),
        current = doc.data['accounts'][uid] as Map<String, dynamic>;
    if (current['generation'] != a['generation'])
      throw const TraeFailure('source_changed');
    final attempts = current['claims'] as Map<String, dynamic>,
        previous = attempts[day];
    if (b['checked_in'] == true || b['did_checked_in'] == true) {
      current['outcome'] = previous?['outcome'] == 'claimed'
          ? 'claimed'
          : 'observedClaimed';
      await _write(doc);
      _credits[uid] = await _readCredits(a);
      return;
    }
    if (previous != null) {
      current['outcome'] = previous['outcome'];
      await _write(doc);
      return;
    }
    if (b['enable'] != true) {
      current['outcome'] = 'ineligible';
      await _write(doc);
      return;
    }
    final baseline = await _readCredits(a);
    _credits[uid] = baseline;
    final operation = _generation();
    attempts[day] = {
      'id': operation,
      'outcome': 'unknown',
      'baseline': baseline.totalRemaining,
    };
    current['outcome'] = 'unknown';
    current['credited'] = null;
    await _write(doc);
    final reserved = await _read();
    if (_closed ||
        reserved.data['accounts'][uid]?['generation'] != a['generation'] ||
        reserved.data['accounts'][uid]?['claims'][day]?['id'] != operation ||
        a['expiresAt'] <= now() ||
        _day(status.serverMs! + elapsed.elapsedMilliseconds) != day)
      throw const TraeFailure('source_changed');
    var received = false;
    try {
      final response = await http.post(
        TraeHttp.claim,
        {'req_source': 1},
        token: a['token'],
        device: a['device'],
        isCurrent: () =>
            !_closed &&
            a['expiresAt'] > now() &&
            _day(status.serverMs! + elapsed.elapsedMilliseconds) == day,
      );
      _validReply(response);
      received = true;
    } catch (_) {
      /* Read-only reconciliation is allowed; never retry this POST. */
    }
    _alive();
    var outcome = 'unknown';
    double? credited;
    try {
      final afterStatus = await _status(a), after = await _readCredits(a);
      _credits[uid] = after;
      if (afterStatus.serverMs != null &&
          _day(afterStatus.serverMs!) == day &&
          (afterStatus.body['checked_in'] == true ||
              afterStatus.body['did_checked_in'] == true)) {
        outcome = received ? 'claimed' : 'observedClaimed';
        if (received &&
            baseline.totalRemaining != null &&
            after.totalRemaining != null) {
          final delta = after.totalRemaining! - baseline.totalRemaining!;
          if (delta > 0) credited = delta;
        }
      }
    } catch (_) {
      /* Keep unknown receipt; no fabricated success or balance. */
    }
    final saved = await _read(), row = saved.data['accounts'][uid];
    if (row?['generation'] != a['generation'] ||
        row?['claims'][day]?['id'] != operation)
      throw const TraeFailure('source_changed');
    row['outcome'] = outcome;
    row['credited'] = credited;
    row['claims'][day]['outcome'] = outcome;
    row['claims'][day]['credited'] = credited;
    await _write(saved);
  });
  Future<void> setAutomatic(String uid, bool enabled) => _exclusive(() async {
    final doc = await _read(), a = doc.data['accounts'][uid];
    if (a == null) throw const TraeFailure('account_missing');
    a['automatic'] = enabled;
    await _write(doc);
  });
  void startAutomatic() {
    if (_closed || _automatic != null) return;
    _startup = Timer(
      const Duration(seconds: 30),
      () => unawaited(automaticTick()),
    );
    _automatic = Timer.periodic(
      const Duration(minutes: 15),
      (_) => unawaited(automaticTick()),
    );
  }

  Future<void> automaticTick() async {
    if (_closed || _busy || _ticking || loginPending) return;
    _ticking = true;
    try {
      for (final a in await accounts()) {
        if (_closed) break;
        if (!a.automatic) continue;
        try {
          await claim(a.uid);
        } on TraeFailure catch (e) {
          message = 'TRAE CN 检查未完成（${e.code}）。';
        }
      }
    } catch (_) {
      message = 'TRAE CN 本机记录暂时无法读取。';
    } finally {
      _ticking = false;
      await _notify();
    }
  }

  void dispose() {
    _closed = true;
    cancelAuthorization();
    _startup?.cancel();
    _automatic?.cancel();
  }
}
