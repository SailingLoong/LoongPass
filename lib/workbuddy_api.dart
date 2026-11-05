// Minimal port of candidate-669/src-tauri/src/workbuddy/{authorization,http,protocol}.rs.
// Existing MIT notices retained. No signatures, credential persistence or UI.
import 'dart:convert';
import 'dart:io';
import 'native_account_gate.dart';
import 'workbuddy_claim.dart';
import 'workbuddy_balance.dart';
import 'workbuddy_vault.dart';

class WorkBuddyApiFailure implements Exception {
  final String code;

  /// False only with positive evidence that dispatch did not begin.
  final bool mayHaveBeenSent;
  const WorkBuddyApiFailure(this.code, {this.mayHaveBeenSent = true});
  @override
  String toString() => code;
}

Never _fail(String code) => throw WorkBuddyApiFailure(code);
// Production access is compile-time closed independently of other platforms.
// Synthetic exchanges are explicitly injected by tests; there is no bypass
// option on the actual HTTPS transport.
void requireWorkBuddyProductionAccess() {
  if (!workBuddyNativeAdapterValidated) {
    throw const WorkBuddyApiFailure(
      'WorkBuddyUnavailable',
      mayHaveBeenSent: false,
    );
  }
}

void requireWorkBuddyIdentityAccess() {
  if (!workBuddyMemoryIdentityApproved)
    throw const WorkBuddyApiFailure(
      'WorkBuddyIdentityUnavailable',
      mayHaveBeenSent: false,
    );
}

bool _success(Map m) => [0, 200, '0', '200'].contains(m['code']);
bool _safe(String s, int max) =>
    s.trim().isNotEmpty &&
    s.length <= max &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(s);
String? _text(Map m, List<String> keys) {
  for (final k in keys) {
    final v = m[k];
    if (v is String && v.trim().isNotEmpty) return v;
  }
  return null;
}

void _personal(Map m, {bool requiredIdentity = false}) {
  if ([
        'enterpriseId',
        'enterprise_id',
      ].any((k) => m[k] != null && m[k] != '') ||
      ((requiredIdentity || m.containsKey('type')) &&
          !(m['type'] is String &&
              [
                'personal',
                'pro',
              ].contains((m['type'] as String).trim().toLowerCase()))))
    _fail('UnsupportedContext');
}

class WorkBuddyAccount {
  final String domain, uid;
  final String _token;
  final DateTime? expiresAt;
  WorkBuddyAccount(this.domain, this.uid, this._token, {this.expiresAt}) {
    if (!['www.workbuddy.cn', 'www.codebuddy.cn'].contains(domain) ||
        !_safe(uid, 256) ||
        !_safe(_token, 16384) ||
        _token.codeUnits.any((v) => v > 126))
      _fail('UnsupportedCredential');
  }
  @override
  String toString() => 'WorkBuddyAccount(redacted)';
}

class WorkBuddyRequest {
  final Uri uri;
  final String method;
  final Map<String, String> headers;
  final String body;
  WorkBuddyRequest(
    this.uri,
    this.method,
    Map<String, String> headers, {
    Map<String, Object?> body = const {},
  }) : headers = Map.unmodifiable(headers),
       body = jsonEncode(body);
  @override
  String toString() => 'WorkBuddyRequest(redacted)';
}

abstract interface class WorkBuddyExchange {
  Future<Map<String, Object?>> send(
    WorkBuddyRequest request,
    bool Function() admitted,
  );
}

/// The same authorization API, bounded to three identity endpoints. Applied
/// also to injected synthetic exchanges so tests exercise the actual policy.
class WorkBuddyIdentityExchange implements WorkBuddyExchange {
  final WorkBuddyExchange _inner;
  WorkBuddyIdentityExchange(this._inner);
  static bool permits(WorkBuddyRequest r) {
    const methods = {
      '/v2/plugin/auth/state': 'POST',
      '/v2/plugin/auth/token': 'GET',
      '/v2/plugin/account': 'GET',
    };
    return r.uri.scheme == 'https' &&
        ['www.workbuddy.cn', 'www.codebuddy.cn'].contains(r.uri.host) &&
        r.uri.port == 443 &&
        r.uri.userInfo.isEmpty &&
        !r.uri.hasFragment &&
        methods[r.uri.path] == r.method;
  }

  @override
  Future<Map<String, Object?>> send(
    WorkBuddyRequest r,
    bool Function() admitted,
  ) {
    if (!permits(r) || !admitted())
      throw const WorkBuddyApiFailure(
        'IdentityRequestUnavailable',
        mayHaveBeenSent: false,
      );
    return _inner.send(r, admitted);
  }
}

/// Actual HTTPS implementation. Tests inject a fake; no live traffic was tested.
class WorkBuddyHttps implements WorkBuddyExchange {
  final bool identityValidationOnly;
  WorkBuddyHttps() : identityValidationOnly = false;
  WorkBuddyHttps.identityValidation() : identityValidationOnly = true;
  void requireAccess() {
    if (identityValidationOnly) {
      requireWorkBuddyIdentityAccess();
    } else {
      requireWorkBuddyProductionAccess();
    }
  }

  bool get _accessApproved => identityValidationOnly
      ? workBuddyMemoryIdentityApproved
      : workBuddyNativeAdapterValidated;
  @override
  Future<Map<String, Object?>> send(
    WorkBuddyRequest r,
    bool Function() admitted,
  ) async {
    requireAccess();
    if (identityValidationOnly && !WorkBuddyIdentityExchange.permits(r))
      throw const WorkBuddyApiFailure(
        'IdentityRequestUnavailable',
        mayHaveBeenSent: false,
      );
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..userAgent = 'LoongPass';
    var dispatched = false, finished = false;
    bool allowed() => _accessApproved && !finished && admitted();
    Future<Map<String, Object?>> run() async {
      final uri = r.uri;
      if (uri.scheme != 'https' ||
          !['www.workbuddy.cn', 'www.codebuddy.cn'].contains(uri.host) ||
          uri.port != 443 ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment)
        _fail('UnsupportedContext');
      if (!allowed()) _fail('ExpiredAuthorization');
      final request = await client.openUrl(r.method, uri);
      request.followRedirects = false;
      request.maxRedirects = 0;
      if (!allowed()) {
        request.abort();
        _fail('ExpiredAuthorization');
      }
      r.headers.forEach(request.headers.set);
      // write() can begin sending: mark uncertainty BEFORE writing any bytes.
      if (!allowed()) {
        request.abort();
        _fail('ExpiredAuthorization');
      }
      dispatched = true;
      if (r.method == 'POST') {
        request.headers.contentType = ContentType.json;
        request.write(r.body);
      }
      final response = await request.close();
      if (response.statusCode == 401 || response.statusCode == 403)
        _fail('NeedsVerification');
      if (response.statusCode < 200 || response.statusCode >= 300)
        _fail('OutcomeUnknown');
      const max = 4 * 1024 * 1024;
      if (response.contentLength > max) _fail('ResponseTooLarge');
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > max) _fail('ResponseTooLarge');
        bytes.addAll(chunk);
      }
      if (!allowed()) _fail('ExpiredAuthorization');
      final body = jsonDecode(utf8.decode(bytes));
      if (body is! Map<String, dynamic>) _fail('InvalidResponse');
      return Map<String, Object?>.from(body);
    }

    try {
      return await run().timeout(const Duration(seconds: 20));
    } on WorkBuddyApiFailure catch (e) {
      throw WorkBuddyApiFailure(e.code, mayHaveBeenSent: dispatched);
    } catch (_) {
      throw WorkBuddyApiFailure('OutcomeUnknown', mayHaveBeenSent: dispatched);
    } finally {
      finished = true;
      client.close(force: true);
    }
  }
}

class WorkBuddyApi {
  final WorkBuddyExchange exchange;
  final bool Function() isCurrent;
  final DateTime Function() now;
  // Connection authority is independent of the token's account domain.
  final String endpointHost;
  Future<bool> Function()? prepareAdmission;
  int _epoch = 0;
  String? _state;
  WorkBuddyAccount? _pendingAccount;
  DateTime? _expires;
  Stopwatch? _elapsed;
  bool _polling = false;
  WorkBuddyApi(
    this.exchange, {
    required this.isCurrent,
    DateTime Function()? now,
    this.endpointHost = 'www.workbuddy.cn',
    this.prepareAdmission,
  }) : now = now ?? DateTime.now {
    if (!['www.workbuddy.cn', 'www.codebuddy.cn'].contains(endpointHost))
      _fail('UnsupportedContext');
  }
  void cancel() {
    _epoch++;
    _state = null;
    _pendingAccount = null;
    _expires = null;
    _elapsed?.stop();
    _elapsed = null;
  }

  bool _flow(int e) =>
      e == _epoch &&
      isCurrent() &&
      _expires != null &&
      now().isBefore(_expires!) &&
      _elapsed != null &&
      _elapsed!.elapsed < const Duration(minutes: 5);
  Future<Map<String, Object?>> _send(
    String path, {
    WorkBuddyAccount? account,
    String? state,
    String method = 'POST',
    bool Function()? gate,
    bool claim = false,
    Map<String, Object?> body = const {},
  }) async {
    final host = endpointHost;
    final query = path.endsWith('/auth/state')
        ? {'platform': 'workbuddy'}
        : state != null
        ? {'state': state}
        : null;
    final headers = <String, String>{'Accept': 'application/json'};
    if (path.endsWith('/auth/state') || path.endsWith('/auth/token')) {
      for (final name in [
        'Authorization',
        'User-Id',
        'Enterprise-Id',
        'Department-Info',
      ]) {
        headers['X-No-$name'] = 'true';
      }
      if (path.endsWith('/auth/state')) headers['X-Domain'] = endpointHost;
    }
    if (account != null) {
      headers.addAll({
        'Authorization': 'Bearer ${account._token}',
        'X-Domain': account.domain,
      });
      if (path != '/v2/plugin/account') headers['X-User-Id'] = account.uid;
    }
    final epoch = _epoch;
    bool admitted() =>
        epoch == _epoch &&
        isCurrent() &&
        (gate?.call() ?? true) &&
        (account?.expiresAt == null || now().isBefore(account!.expiresAt!));
    if (!admitted() ||
        (prepareAdmission != null && !await prepareAdmission!()) ||
        !admitted())
      throw const WorkBuddyApiFailure(
        'ExpiredAuthorization',
        mayHaveBeenSent: false,
      );
    try {
      final result = await exchange.send(
        WorkBuddyRequest(
          Uri.https(host, path, query),
          method,
          headers,
          body: body,
        ),
        admitted,
      );
      if (!admitted()) _fail('ExpiredAuthorization');
      return result;
    } on WorkBuddyApiFailure catch (e) {
      if (claim && e.mayHaveBeenSent)
        throw const WorkBuddyApiFailure('OutcomeUnknown');
      rethrow;
    } catch (_) {
      _fail('OutcomeUnknown');
    }
  }

  Future<Uri> begin() async {
    cancel();
    final epoch = _epoch;
    _expires = now().add(const Duration(minutes: 5));
    _elapsed = Stopwatch()..start();
    try {
      final response = await _send(
        '/v2/plugin/auth/state',
        gate: () => _flow(epoch),
      );
      if (!_success(response) || response['data'] is! Map)
        _fail('NeedsVerification');
      final d = response['data'] as Map;
      final state = _text(d, ['state']);
      final raw = _text(d, ['authUrl', 'auth_url', 'url']);
      if (state == null || !_safe(state, 4096) || raw == null)
        _fail('InvalidAuthorization');
      final url = Uri.tryParse(raw);
      if (url == null ||
          url.scheme != 'https' ||
          !['www.workbuddy.cn', 'www.codebuddy.cn'].contains(url.host) ||
          url.port != 443 ||
          url.userInfo.isNotEmpty ||
          url.hasFragment ||
          url.queryParametersAll['state']?.length != 1 ||
          url.queryParameters['state'] != state ||
          url.queryParameters.keys.any(
            (k) =>
                k.toLowerCase().contains('token') ||
                k.toLowerCase().contains('password'),
          ))
        _fail('InvalidAuthorization');
      if (!_flow(epoch)) _fail('ExpiredAuthorization');
      _state = state;
      return url.replace(host: endpointHost);
    } catch (_) {
      if (epoch == _epoch) cancel();
      rethrow;
    }
  }

  Future<WorkBuddyAccount?> poll() async {
    final epoch = _epoch;
    if (!_flow(epoch) || _state == null) _fail('ExpiredAuthorization');
    if (_polling) _fail('Busy');
    _polling = true;
    try {
      if (_pendingAccount == null) {
        final token = await _send(
          '/v2/plugin/auth/token',
          state: _state,
          method: 'GET',
          gate: () => _flow(epoch),
        );
        final pending = [11217, '11217'].contains(token['code']);
        final payload = token['data'];
        if (pending &&
            (payload is! Map ||
                payload['accessToken'] is! String ||
                (payload['accessToken'] as String).isEmpty))
          return null;
        if ((!_success(token) && !pending) || payload is! Map)
          _fail('NeedsVerification');
        final d = token['data'] as Map;
        _personal(d);
        final secret = _text(d, ['accessToken']);
        if (secret == null) _fail('InvalidAuthorization');
        final rawDomain = d['domain'];
        if (rawDomain != null && (rawDomain is! String || rawDomain.isEmpty))
          _fail('UnsupportedContext');
        final domain = rawDomain as String? ?? endpointHost;
        DateTime? tokenDeadline;
        for (final field in ['expiresAt', 'expiresIn']) {
          if (!d.containsKey(field)) continue;
          final value = d[field];
          if (value is! num ||
              !value.isFinite ||
              value <= 0 ||
              value > (field == 'expiresAt' ? 8640000000000000 : 8640000000000))
            _fail('InvalidAuthorization');
          if (field == 'expiresIn' &&
              value * 1000 > 8640000000000000 - now().millisecondsSinceEpoch)
            _fail('InvalidAuthorization');
          final deadline = DateTime.fromMillisecondsSinceEpoch(
            field == 'expiresAt'
                ? value.toInt()
                : now().millisecondsSinceEpoch + (value * 1000).toInt(),
            isUtc: true,
          );
          if (!now().isBefore(deadline)) _fail('ExpiredAuthorization');
          if (tokenDeadline == null || deadline.isBefore(tokenDeadline))
            tokenDeadline = deadline;
        }
        _pendingAccount = WorkBuddyAccount(
          domain,
          'authorization-pending',
          secret,
          expiresAt: tokenDeadline,
        );
      }
      final temporary = _pendingAccount!;
      final domain = temporary.domain;
      bool authorized() =>
          _flow(epoch) &&
          (temporary.expiresAt == null || now().isBefore(temporary.expiresAt!));
      final response = await _send(
        '/v2/plugin/account',
        account: temporary,
        method: 'GET',
        gate: authorized,
      );
      if ([12151, '12151'].contains(response['code'])) return null;
      if (!_success(response) || response['data'] is! Map)
        _fail('NeedsVerification');
      final p = response['data'] as Map;
      _personal(p, requiredIdentity: true);
      if (p['domain'] != null && p['domain'] != domain)
        _fail('IdentityMismatch');
      final uid = _text(p, ['uid']);
      if (uid == null) _fail('UnsupportedContext');
      final account = WorkBuddyAccount(
        domain,
        uid,
        temporary._token,
        expiresAt: temporary.expiresAt,
      );
      if (!authorized()) _fail('ExpiredAuthorization');
      cancel();
      return account;
    } finally {
      _polling = false;
    }
  }

  bool matchesStoredAccount(
    WorkBuddyAccount account,
    WorkBuddyVaultCredential c,
  ) =>
      account.domain == c.domain &&
      account.uid == c.uid &&
      account._token == c.accessToken &&
      account.expiresAt == c.expiresAt &&
      endpointHost == c.endpoint;
  Future<bool> saveVerifiedAccount(
    WorkBuddyAccount account,
    WorkBuddyVault vault,
    String key, {
    required bool Function() gate,
  }) async {
    final expires = account.expiresAt;
    if (!isCurrent() ||
        !gate() ||
        (expires != null && !now().isBefore(expires)))
      return false;
    return vault.save(
      key,
      WorkBuddyVaultCredential(
        domain: account.domain,
        endpoint: endpointHost,
        uid: account.uid,
        accessToken: account._token,
        expiresAt: expires,
      ),
      admission: () => isCurrent() && gate(),
      replaceVerified: true,
    );
  }

  /// Revalidate a saved identity through the same strict personal profile
  /// contract as login. No auth-token poll, refresh or claim is sent here.
  Future<void> verifyStoredAccount(
    WorkBuddyAccount account, {
    required bool Function() gate,
  }) async {
    if (account.expiresAt != null && !now().isBefore(account.expiresAt!))
      throw const WorkBuddyApiFailure(
        'ExpiredAuthorization',
        mayHaveBeenSent: false,
      );
    final response = await _send(
      '/v2/plugin/account',
      account: account,
      method: 'GET',
      gate: gate,
    );
    if (!_success(response) || response['data'] is! Map)
      _fail('NeedsVerification');
    final p = response['data'] as Map;
    _personal(p, requiredIdentity: true);
    if (_text(p, ['uid']) != account.uid ||
        (p['domain'] != null && p['domain'] != account.domain))
      _fail('IdentityMismatch');
  }

  Future<Map<String, Object?>> status(WorkBuddyAccount account) =>
      _send('/v2/billing/meter/checkin-activity-status', account: account);
  Future<({WorkBuddySubject subject, double? totalRemaining})> completeBalance(
    WorkBuddyAccount account,
    WorkBuddySubject subject, {
    required bool Function() gate,
  }) async {
    final credits = await creditDetails(account, subject, gate: gate);
    return (subject: subject, totalRemaining: credits?.totalRemaining);
  }

  Future<CreditSummary?> creditDetails(
    WorkBuddyAccount account,
    WorkBuddySubject subject, {
    required bool Function() gate,
  }) async {
    if (account.domain != subject.domain || account.uid != subject.uid) {
      throw const WorkBuddyFailure('IdentityMismatch');
    }
    final epoch = _epoch;
    bool admitted() => epoch == _epoch && isCurrent() && gate();
    if (!admitted())
      throw const WorkBuddyApiFailure(
        'ExpiredAuthorization',
        mayHaveBeenSent: false,
      );
    final observedAt = now().toUtc();
    String day(DateTime value) => value
        .toUtc()
        .add(const Duration(hours: 8))
        .toIso8601String()
        .substring(0, 10);
    final chinaDay = day(observedAt);
    final summary = await _send(
      '/billing/meter/get-user-resource-summary',
      account: account,
      gate: admitted,
    );
    if (day(now()) != chinaDay) return null;
    final paid = await _send(
      '/billing/meter/get-user-resource-paid-packages',
      account: account,
      gate: admitted,
      body: {
        'PageNumber': 1,
        'PageSize': 200,
        'Status': [0, 3],
        'PackageCodes': _paidCodes,
        'NeedRenewInfo': true,
        'IsDisplayTotalInfo': true,
      },
    );
    if (day(now()) != chinaDay) return null;
    final free = await _send(
      '/billing/meter/get-user-resource-free-packages',
      account: account,
      gate: admitted,
      body: {
        'PageNumber': 1,
        'PageSize': 200,
        'Status': [0, 3],
        'PackageCodes': _freeCodes,
        'SlicePeriodStartTime': '$chinaDay 00:00:00',
        'SlicePeriodEndTime': '$chinaDay 23:59:59',
        'IsDisplayTotalInfo': true,
      },
    );
    if (!admitted()) throw const WorkBuddyApiFailure('ExpiredAuthorization');
    if (day(now()) != chinaDay) return null;
    return normalizeWorkBuddyCredits(summary, paid, free, now: observedAt);
  }

  /// One network attempt, not an idempotency scheduler. Existing owner/core must
  /// persist intent and prevent replays. A success receipt is NOT credited proof.
  Future<Map<String, Object?>> claimOnce(WorkBuddyAccount account) =>
      _send('/v2/billing/meter/daily-checkin', account: account, claim: true);
}

// Pinned mature request lists, not new product discovery or speculative paging.
const _paidCodes = [
  'TCACA_code_002_AkiJS3ZHF5',
  'TCACA_code_023_4xbGhMrE6q',
  'TCACA_code_026_BaESVICNoi',
  'TCACA_code_027_0FCGVA6vSa',
  'TCACA_code_009_0XmEQc2xOf',
  'TCACA_code_038_OhvqZtiPKr',
  'TCACA_code_003_FAnt7lcmRT',
  'TCACA_code_036_lupO5WgNdG',
];
const _freeCodes = [
  'TCACA_code_008_cfWoLwvjU4',
  'TCACA_code_007_nzdH5h4Nl0',
  'TCACA_code_028_NtpWi0jzXs',
  'TCACA_code_029_6wCGEWquYy',
  'TCACA_code_030_BjSt89qTvr',
  'TCACA_code_001_PqouKr6QWV',
  'TCACA_code_006_DbXS0lrypC',
  'TCACA_code_035_ArVxJcGDsm',
  'TCACA_code_037_WxOD3MpI2o',
  'TCACA_code_039_KRcQj7wUat',
  'TCACA_code_040_mi9rCYg46x',
];

/// Existing authenticated owner supplies a complete normalized total, never a
/// partial package sum. Null means unavailable. Identity includes generation.
typedef WorkBuddyBalanceReader =
    Future<({WorkBuddySubject subject, double? totalRemaining})> Function(
      WorkBuddySubject subject,
    );

/// Thin connection to the existing claim core. The same owner must bind API,
/// credential generation, durable store and complete-balance reader together.
class WorkBuddyApiTransport implements WorkBuddyTransport {
  final WorkBuddyApi api;
  final WorkBuddyAccount account;
  final WorkBuddySubject subject;
  final WorkBuddyBalanceReader readCompleteBalance;
  WorkBuddyApiTransport(
    this.api,
    this.account,
    this.subject, {
    required this.readCompleteBalance,
  }) {
    if (account.domain != subject.domain || account.uid != subject.uid)
      throw const WorkBuddyFailure('IdentityMismatch');
  }
  void _check(WorkBuddySubject requested, int epoch) {
    if (!subject.matches(requested))
      throw const WorkBuddyFailure('IdentityMismatch');
    if (epoch != api._epoch || !api.isCurrent())
      throw const WorkBuddyFailure('ExpiredAuthorization');
  }

  @override
  Future<WorkBuddyObservation> observe(WorkBuddySubject requested) async {
    final epoch = api._epoch;
    _check(requested, epoch);
    final status = await api.status(account);
    _check(requested, epoch);
    final balance = await readCompleteBalance(requested);
    _check(requested, epoch);
    if (!requested.matches(balance.subject))
      throw const WorkBuddyFailure('IdentityMismatch');
    final total = balance.totalRemaining;
    return WorkBuddyObservation(
      requested,
      status,
      total != null && total.isFinite && total >= 0 ? total : null,
    );
  }

  @override
  Future<Map<String, Object?>> claim(WorkBuddySubject requested) async {
    _check(requested, api._epoch);
    return api.claimOnce(account);
  }
}
