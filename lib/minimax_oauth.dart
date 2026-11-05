// Official MiniMax-AI/minimax-code oauth-core protocol (MIT), 9a935605.
import 'dart:convert';
import 'dart:math';
import 'minimax_http.dart';
import 'source_digest.dart';

class MiniMaxOAuthFailure implements Exception {
  final String code;
  const MiniMaxOAuthFailure(this.code);
  @override
  String toString() => 'MiniMaxOAuthFailure($code)';
}

class MiniMaxOAuthToken {
  final String accessToken;
  final int expiresAtMs;
  final String? refreshToken;
  const MiniMaxOAuthToken(
    this.accessToken,
    this.expiresAtMs, [
    this.refreshToken,
  ]);
  @override
  String toString() => 'MiniMaxOAuthToken(redacted)';
}

class MiniMaxOAuth {
  final String region;
  final MiniMaxHttp http;
  final int Function() nowMs;
  int _epoch = 0, _expires = 0, _nextPoll = 0, _interval = 5000;
  String? _verifier, _device;
  bool _legacy = false, _busy = false;
  MiniMaxOAuthToken? _token;
  String? userCode;
  MiniMaxOAuth({
    required this.region,
    required this.http,
    int Function()? nowMs,
  }) : nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);
  bool get active =>
      _verifier != null && nowMs() < (_token?.expiresAtMs ?? _expires);
  void cancel() {
    _epoch++;
    _verifier = null;
    _device = null;
    _token = null;
    userCode = null;
  }

  Future<Uri> begin() async {
    if (_busy || active) throw const MiniMaxOAuthFailure('busy');
    if (!['cn', 'global'].contains(region))
      throw const MiniMaxOAuthFailure('invalid_region');
    _busy = true;
    final epoch = ++_epoch;
    try {
      final verifier = base64Url
          .encode(List.generate(32, (_) => Random.secure().nextInt(256)))
          .replaceAll('=', '');
      final challenge = base64Url
          .encode(sourceSha256(utf8.encode(verifier)))
          .replaceAll('=', '');
      final reply = await http.oauth('/oauth2/device/code', region, {
        'client_id': 'mcode-public',
        'scope': 'agent.default',
        'audience': 'agent-backend',
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
      }, isCurrent: () => epoch == _epoch);
      if (epoch != _epoch) throw const MiniMaxOAuthFailure('cancelled');
      final body = reply.body;
      if (reply.status != 200 || body == null || body['error'] != null)
        throw const MiniMaxOAuthFailure('invalid_response');
      final code = _text(body['user_code']),
          standard = _text(body['device_code']);
      final legacy = _positive(body['expired_in']);
      _legacy = standard == null && legacy != null;
      final device = standard ?? (_legacy ? code : null);
      final seconds =
          _positive(body['expires_in']) ??
          (legacy == null
              ? null
              : legacy >= 1e12
              ? (legacy - nowMs()) / 1000
              : legacy);
      if (code == null ||
          device == null ||
          seconds == null ||
          seconds <= 0 ||
          seconds > 86400)
        throw const MiniMaxOAuthFailure('invalid_response');
      final uri = Uri.tryParse(
        _text(
              body['verification_uri_complete'] ??
                  body['verification_uri'] ??
                  body['verification_url'],
            ) ??
            '',
      );
      final hosts = region == 'cn'
          ? {
              'account.minimax.cn',
              'agent.minimaxi.com',
              'agent.minimax.cn',
              'code.minimax.cn',
            }
          : {'account.minimax.io', 'agent.minimax.io', 'code.minimax.io'};
      if (uri == null ||
          uri.scheme != 'https' ||
          !hosts.contains(uri.host) ||
          uri.port != 443 ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          uri.queryParameters.keys.any(
            (k) =>
                k.toLowerCase().contains('token') ||
                {'device_code', 'code_verifier'}.contains(k.toLowerCase()),
          ))
        throw const MiniMaxOAuthFailure('invalid_authorization_url');
      _interval =
          ((_positive(body['interval']) ?? (_legacy ? 5000 : 5)) *
                  (_legacy ? 1 : 1000))
              .round()
              .clamp(1000, 300000);
      _expires = nowMs() + (seconds * 1000).floor();
      _nextPoll = 0;
      _verifier = verifier;
      _device = device;
      userCode = code;
      _token = null;
      return uri;
    } finally {
      _busy = false;
    }
  }

  Future<MiniMaxOAuthToken?> poll() async {
    if (!active) throw const MiniMaxOAuthFailure('expired');
    if (_token != null)
      return _token; // Profile/storage retries reuse this result.
    if (_busy || nowMs() < _nextPoll) return null;
    _busy = true;
    final epoch = _epoch;
    try {
      _nextPoll = nowMs() + _interval;
      final response = await http.oauth('/oauth2/token', region, {
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        'client_id': 'mcode-public',
        'code_verifier': _verifier!,
        _legacy ? 'user_code' : 'device_code': _device!,
      }, isCurrent: () => epoch == _epoch && active);
      if (epoch != _epoch || !active)
        throw const MiniMaxOAuthFailure('expired');
      final b = response.body ?? {};
      final state = b['error'] ?? b['status'];
      if (response.status == 429 || response.status >= 500)
        throw const MiniMaxOAuthFailure('temporarily_unavailable');
      if ({'authorization_pending', 'pending', 'slow_down'}.contains(state)) {
        if (state == 'slow_down') _interval += 5000;
        _nextPoll = nowMs() + _interval;
        return null;
      }
      if (response.status < 200 ||
          response.status >= 300 ||
          b['error'] != null ||
          {
            'denied',
            'access_denied',
            'expired',
            'expired_token',
          }.contains(state)) {
        cancel();
        throw const MiniMaxOAuthFailure('authorization_rejected');
      }
      _token = _parseToken(b, nowMs());
      return _token;
    } finally {
      _busy = false;
    }
  }

  static Future<MiniMaxOAuthToken> refresh({
    required MiniMaxHttp http,
    required String region,
    required String refreshToken,
    required int Function() nowMs,
  }) async {
    MiniMaxReply response;
    try {
      response = await http.oauth('/oauth2/token', region, {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': 'mcode-public',
        'scope': 'agent.default',
        'audience': 'agent-backend',
      });
    } catch (_) {
      throw const MiniMaxOAuthFailure('temporarily_unavailable');
    }
    final b = response.body;
    if (response.status == 400 && b?['error'] == 'invalid_grant')
      throw const MiniMaxOAuthFailure('invalid_grant');
    if (response.status != 200 || b == null || b['error'] != null)
      throw const MiniMaxOAuthFailure('temporarily_unavailable');
    return _parseToken(b, nowMs(), previousRefresh: refreshToken);
  }

  static MiniMaxOAuthToken _parseToken(
    Map<String, dynamic> b,
    int now, {
    String? previousRefresh,
  }) {
    final access = _text(b['access_token']),
        seconds = _positive(b['expires_in']);
    Object? scope = b['scope'];
    if (scope == null && access != null) {
      try {
        final claims = jsonDecode(
          utf8.decode(
            base64Url.decode(base64Url.normalize(access.split('.')[1])),
          ),
        );
        scope = claims['scope'] ?? claims['scp'];
      } catch (_) {}
    }
    final scopes = scope is String
        ? scope.split(RegExp(r'\s+'))
        : scope is List
        ? scope
        : const [];
    if (access == null ||
        seconds == null ||
        seconds > 31536000 ||
        b['token_type'].toString().toLowerCase() != 'bearer' ||
        !scopes.contains('agent.default'))
      throw const MiniMaxOAuthFailure('invalid_token');
    final refresh = b['refresh_token'] == null
        ? previousRefresh
        : _text(b['refresh_token']);
    if (b['refresh_token'] != null && refresh == null)
      throw const MiniMaxOAuthFailure('invalid_token');
    return MiniMaxOAuthToken(access, now + (seconds * 1000).floor(), refresh);
  }

  static String? _text(Object? v) =>
      v is String &&
          v.isNotEmpty &&
          v.length <= 16384 &&
          !v.codeUnits.any((c) => c < 32 || c == 127)
      ? v
      : null;
  static num? _positive(Object? v) =>
      v is num && v.isFinite && v > 0 ? v : null;
}
