// WorkBuddy-only official desktop profile verification. Native Magpie owns
// browser authorization, token renewal, inference and rewards. MIT provenance
// for the retained strict profile/HTTP contract remains in THIRD_PARTY_NOTICES.md.
import 'dart:convert';
import 'dart:io';

import 'native_account_gate.dart';
import 'workbuddy_desktop_session.dart';

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
  if (m['isCurrentOneIdEnterprise'] == true ||
      [
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
  final String? refreshToken;
  final DateTime? expiresAt, refreshExpiresAt;
  WorkBuddyAccount(
    this.domain,
    this.uid,
    this._token, {
    this.expiresAt,
    this.refreshToken,
    this.refreshExpiresAt,
  }) {
    if (!['www.workbuddy.cn', 'www.codebuddy.cn'].contains(domain) ||
        !_safe(uid, 256) ||
        !_safe(_token, 16384) ||
        _token.codeUnits.any((v) => v > 126) ||
        refreshToken != null &&
            (!_safe(refreshToken!, 16384) ||
                RegExp(r'[^\x21-\x7e]').hasMatch(refreshToken!)))
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

/// Bounded read-only profile transport. It never signs in, refreshes or claims.
class WorkBuddyHttps implements WorkBuddyExchange {
  @override
  Future<Map<String, Object?>> send(
    WorkBuddyRequest r,
    bool Function() admitted,
  ) async {
    requireWorkBuddyProductionAccess();
    if (r.method != 'GET' || r.uri.path != '/v2/plugin/account')
      _fail('UnsupportedContext');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..userAgent = 'LoongPass';
    var dispatched = false, finished = false;
    bool allowed() =>
        workBuddyNativeAdapterValidated && !finished && admitted();
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
  WorkBuddyApi(
    this.exchange, {
    required this.isCurrent,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final WorkBuddyExchange exchange;
  final bool Function() isCurrent;
  final DateTime Function() now;
  Future<Map<String, Object?>> _verifiedProfile(
    WorkBuddyAccount account, {
    required bool Function() gate,
  }) async {
    if (account.expiresAt != null && !now().isBefore(account.expiresAt!))
      throw const WorkBuddyApiFailure(
        'ExpiredAuthorization',
        mayHaveBeenSent: false,
      );
    bool admitted() =>
        isCurrent() &&
        gate() &&
        (account.expiresAt == null || now().isBefore(account.expiresAt!));
    if (!admitted()) _fail('ExpiredAuthorization');
    final response = await exchange.send(
      WorkBuddyRequest(Uri.https(account.domain, '/v2/plugin/account'), 'GET', {
        'Accept': 'application/json',
        'Authorization': 'Bearer ${account._token}',
        'X-Domain': account.domain,
      }),
      admitted,
    );
    if (!admitted()) _fail('ExpiredAuthorization');
    if (!_success(response) || response['data'] is! Map)
      _fail('NeedsVerification');
    final p = response['data'] as Map;
    _personal(p, requiredIdentity: true);
    if (_text(p, ['uid']) != account.uid ||
        (p['domain'] != null && p['domain'] != account.domain))
      _fail('IdentityMismatch');
    if (!gate() || !isCurrent()) _fail('ExpiredAuthorization');
    return Map<String, Object?>.from(p);
  }

  Future<WorkBuddyDesktopSession> desktopSession(
    WorkBuddyAccount account, {
    required bool Function() gate,
  }) async {
    final profile = await _verifiedProfile(account, gate: gate);
    return WorkBuddyDesktopSession(
      verifiedProfile: profile,
      domain: account.domain,
      accessToken: account._token,
      expiresAt: account.expiresAt,
    );
  }
}
