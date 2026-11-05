import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'source_digest.dart';
import 'trae_http.dart';

class TraeOAuthToken {
  final String accessToken, refreshToken;
  final int expiresAt, refreshExpiresAt;
  TraeOAuthToken(
    this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.refreshExpiresAt,
  );
  static bool text(Object? v) =>
      v is String &&
      v.isNotEmpty &&
      v.length <= 16384 &&
      v.codeUnits.every((c) => c >= 33 && c <= 126);
  factory TraeOAuthToken.parse(Map<String, dynamic> result, int now) {
    final access = result['Token'], refresh = result['RefreshToken'];
    if (!text(access) || !text(refresh))
      throw const TraeFailure('invalid_token');
    final expiry = result['TokenExpireAt'],
        duration = result['TokenExpireDuration'],
        refreshExpiry = result['RefreshExpireAt'];
    if (expiry is! int || refreshExpiry is! int)
      throw const TraeFailure('invalid_token');
    final effective = expiry > now
        ? expiry
        : duration is int && duration > 0
        ? now + duration
        : 0;
    if (effective <= now || refreshExpiry <= now)
      throw const TraeFailure('expired');
    return TraeOAuthToken(
      access as String,
      refresh as String,
      effective,
      refreshExpiry,
    );
  }
  @override
  String toString() => 'TraeOAuthToken(redacted)';
}

/// One loopback PKCE grant. Profile/storage retries reuse the acquired token.
class TraeOAuth {
  final TraeTransport http;
  final Map<String, dynamic> device;
  final int Function() now;
  HttpServer? _server;
  Timer? _deadline;
  String? _verifier, _state, _code;
  bool _busy = false, _closed = false;
  TraeOAuthToken? _token;
  TraeOAuth({required this.http, required this.device, required this.now});
  bool get active => !_closed;
  Future<Uri> begin() async {
    if (_server != null || _closed) throw const TraeFailure('busy');
    final random = Random.secure();
    _verifier = base64Url
        .encode(List.generate(48, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    _state = base64Url
        .encode(List.generate(24, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final challenge = base64Url
        .encode(sourceSha256(utf8.encode(_verifier!)))
        .replaceAll('=', '');
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    if (_closed) {
      await server.close(force: true);
      throw const TraeFailure('cancelled');
    }
    _server = server;
    server.listen(_receive, onError: (_) => cancel());
    _deadline = Timer(const Duration(minutes: 10), () {
      if (_token == null) cancel();
    });
    final callback = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      path: '/authorize',
      queryParameters: {'state': _state},
    );
    return Uri.https('www.trae.cn', '/authorization', {
      'login_version': '1',
      'auth_from': 'trae',
      'login_channel': 'native_ide',
      'auth_type': 'local',
      'client_id': 'ono9krqynydwx5',
      'plugin_version': device['ClientVersion'],
      'auth_callback_url': callback.toString(),
      'machine_id': device['MachineID'],
      'device_id': device['DeviceID'],
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'x_device_id': device['DeviceID'],
      'x_machine_id': device['MachineID'],
      'x_device_brand': device['DeviceModel'],
      'x_device_type': device['OSInfo'],
      'x_os_version': device['OSVersion'],
      'x_app_version': device['ClientVersion'],
      'x_app_type': 'stable',
    });
  }

  Future<void> _receive(HttpRequest request) async {
    try {
      final origin = request.headers.value('origin');
      if (origin != null && origin != 'https://www.trae.cn')
        throw const TraeFailure('invalid_callback');
      if (origin != null)
        request.response.headers.set('Access-Control-Allow-Origin', origin);
      request.response.headers.set('Cache-Control', 'no-store');
      if (request.method == 'OPTIONS') {
        request.response.headers.set(
          'Access-Control-Allow-Methods',
          'GET, OPTIONS',
        );
        request.response.statusCode = 204;
        return;
      }
      if (_closed ||
          request.method != 'GET' ||
          request.uri.path != '/authorize' ||
          request.uri.toString().length > 65536 ||
          request.uri.queryParameters['state'] != _state)
        throw const TraeFailure('invalid_callback');
      final codeInfo = jsonDecode(
        request.uri.queryParameters['authCodeInfo'] ?? '',
      );
      if (codeInfo is! Map || !TraeOAuthToken.text(codeInfo['AuthCode']))
        throw const TraeFailure('invalid_callback');
      _code ??= codeInfo['AuthCode'];
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<!doctype html><meta charset="utf-8"><title>LoongPass</title><p>已接收授权，请返回 LoongPass 查看保存结果。</p>',
      );
    } catch (_) {
      request.response.statusCode = 400;
      request.response.write('Invalid authorization callback');
    } finally {
      await request.response.close();
    }
  }

  Future<TraeOAuthToken?> poll() async {
    if (_closed) throw const TraeFailure('authorization_ended');
    if (_token != null) return _token;
    if (_busy || _code == null) return null;
    _busy = true;
    try {
      final reply = await http.post(TraeHttp.exchange, {
        'ClientID': 'ono9krqynydwx5',
        'AuthCode': _code,
        'CodeVerifier': _verifier,
        'DeviceInfo': device,
        'IDEVersion': device['ClientVersion'],
      }, isCurrent: () => !_closed);
      if (_closed) throw const TraeFailure('cancelled');
      if (reply.status != 200 ||
          reply.body['Result'] is! Map<String, dynamic>) {
        if (reply.status >= 400 && reply.status < 500) {
          cancel();
          throw const TraeFailure('authorization_rejected');
        }
        throw const TraeFailure('network_unavailable');
      }
      _token = TraeOAuthToken.parse(reply.body['Result'], now());
      _deadline?.cancel();
      await _server?.close(force: true);
      _server = null;
      return _token;
    } finally {
      _busy = false;
    }
  }

  void cancel() {
    _closed = true;
    _deadline?.cancel();
    unawaited(_server?.close(force: true));
    _server = null;
    _code = null;
    _verifier = null;
    _state = null;
    _token = null;
  }
}
