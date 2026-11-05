// Wire reference: MiniMax-AI/minimax-code 9a935605956c4500e9cb415f29258e2887e97817.
// Port of the project's http.rs profile/status/claim protocol only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

enum MiniMaxEndpoint { profile, status, claim, creditDetails }

class MiniMaxReply {
  final int status;
  final Map<String, dynamic>? body;
  const MiniMaxReply(this.status, this.body);
  @override
  String toString() => 'MiniMaxReply(status: $status, body: [redacted])';
}

class MiniMaxHttpException implements Exception {
  final String code;
  const MiniMaxHttpException(this.code);
  @override
  String toString() => 'MiniMaxHttpException($code)';
}

class MiniMaxWireRequest {
  final Uri uri;
  final String method;
  final Map<String, String> headers;
  final String? body;
  MiniMaxWireRequest(
    this.uri,
    this.method,
    Map<String, String> headers,
    this.body,
  ) : headers = Map.unmodifiable(headers);
  @override
  String toString() => 'MiniMaxWireRequest($method, [redacted])';
}

String _encode(String value, {required bool form}) {
  final out = StringBuffer();
  for (final b in utf8.encode(value)) {
    if ((b >= 65 && b <= 90) ||
        (b >= 97 && b <= 122) ||
        (b >= 48 && b <= 57) ||
        (form ? '*-._' : "-_.!~*'()").codeUnits.contains(b)) {
      out.writeCharCode(b);
    } else if (form && b == 32) {
      out.write('+');
    } else {
      out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

bool _controls(String s) =>
    s.runes.any((r) => r < 32 || (r >= 127 && r <= 159));
MiniMaxWireRequest buildMiniMaxRequest(
  MiniMaxEndpoint endpoint, {
  required String accessToken,
  required String region,
  String? userId,
  int? nowMilliseconds,
  int? timezoneOffsetSeconds,
  String? os,
  String version = '1.0.0',
  int pageNumber = 1,
}) {
  if (region != 'cn' && region != 'global')
    throw const MiniMaxHttpException('unsupported_region');
  if (accessToken.trim().isEmpty ||
      utf8.encode(accessToken).length > 16384 ||
      _controls(accessToken) ||
      accessToken.runes.any((r) => r > 255))
    throw const MiniMaxHttpException('needs_login');
  final uid = endpoint == MiniMaxEndpoint.profile ? '0' : userId?.trim();
  if (uid == null ||
      uid.isEmpty ||
      utf8.encode(uid).length > 256 ||
      _controls(userId ?? ''))
    throw const MiniMaxHttpException('needs_login');
  final now = nowMilliseconds ?? DateTime.now().millisecondsSinceEpoch;
  final zone = timezoneOffsetSeconds ?? DateTime.now().timeZoneOffset.inSeconds;
  final language = region == 'cn' ? 'zh' : 'en';
  final operatingSystem =
      os ??
      (Platform.isWindows
          ? 'win32'
          : Platform.isMacOS
          ? 'darwin'
          : Platform.operatingSystem);
  final path = switch (endpoint) {
    MiniMaxEndpoint.profile => '/v1/api/user/info',
    MiniMaxEndpoint.status => '/minimax-cloud/api/v1/signin/status',
    MiniMaxEndpoint.claim => '/minimax-cloud/api/v1/signin/claim',
    MiniMaxEndpoint.creditDetails => '/minimax-cloud/api/v1/credit/details',
  };
  final pairs = <String, String>{
    'device_platform': endpoint == MiniMaxEndpoint.profile ? 'mcode' : 'web',
    'biz_id': '3',
    'app_id': '3001',
    'version_code': '22201',
    if (endpoint != MiniMaxEndpoint.profile) ...{
      'is_desktop': '1',
      'desktop_version': version.trim(),
    },
    'unix': '$now',
    'timezone_offset': '$zone',
    'sys_language': language,
    'lang': language,
    'device_id': '0',
    'os_name': operatingSystem,
    'browser_name': 'mcode',
    'user_id': uid,
    'client': 'mcode',
    if (endpoint == MiniMaxEndpoint.creditDetails) ...{
      'page_number': '$pageNumber',
      'page_size': '20',
      'include_expired': 'true',
    },
  };
  final query = pairs.entries
      .map(
        (e) => '${_encode(e.key, form: true)}=${_encode(e.value, form: true)}',
      )
      .join('&');
  final body = endpoint == MiniMaxEndpoint.claim ? '{}' : null;
  final seconds = '${now ~/ 1000}';
  return MiniMaxWireRequest(
    _ExactQueryUri(
      Uri.parse(
        'https://${region == 'cn' ? 'agent.minimax.cn' : 'agent.minimax.io'}$path',
      ),
      query,
    ),
    body == null ? 'GET' : 'POST',
    {
      'accept': 'application/json',
      'content-type': 'application/json',
      'user-agent': 'MiniMaxCode',
      'authorization': 'Bearer $accessToken',
      'yy': miniMaxWireMd5(
        '${_encode('$path?$query', form: false)}_${body ?? '{}'}${miniMaxWireMd5('$now')}ooui',
      ),
      'x-timestamp': seconds,
      'x-signature': miniMaxWireMd5(
        '${seconds}I*7Cf%WZ#S&%1RlZJ&C2${body ?? ''}',
      ),
    },
    body,
  );
}

class MiniMaxHttp {
  final Duration timeout;
  final int maxResponseBytes;
  final String version;
  final HttpClient Function() _clientFactory;
  MiniMaxHttp({
    this.timeout = const Duration(seconds: 30),
    this.maxResponseBytes = 1024 * 1024,
    this.version = '1.0.0',
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;
  Future<MiniMaxReply> credits({
    required String accessToken,
    required String region,
    required String userId,
    required int pageNumber,
    bool Function()? isCurrent,
  }) async {
    if (pageNumber < 1 || pageNumber > 500)
      throw const MiniMaxHttpException('invalid_page');
    final wire = buildMiniMaxRequest(
      MiniMaxEndpoint.creditDetails,
      accessToken: accessToken,
      region: region,
      userId: userId,
      pageNumber: pageNumber,
      version: version,
    );
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      return await _sendOnce(client, wire, isCurrent).timeout(timeout);
    } on MiniMaxHttpException {
      rethrow;
    } catch (_) {
      throw const MiniMaxHttpException('network_unavailable');
    } finally {
      client.close(force: true);
    }
  }

  Future<MiniMaxReply> oauth(
    String path,
    String region,
    Map<String, String> values, {
    bool Function()? isCurrent,
  }) async {
    if (!['cn', 'global'].contains(region) ||
        !['/oauth2/device/code', '/oauth2/token'].contains(path)) {
      throw const MiniMaxHttpException('unsupported_context');
    }
    final wire = MiniMaxWireRequest(
      Uri.https(
        region == 'cn' ? 'account.minimax.cn' : 'account.minimax.io',
        path,
      ),
      'POST',
      {
        'accept': 'application/json',
        'content-type': 'application/x-www-form-urlencoded',
      },
      values.entries
          .map(
            (e) =>
                '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
          )
          .join('&'),
    );
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      return await _sendOnce(client, wire, isCurrent).timeout(timeout);
    } on MiniMaxHttpException {
      rethrow;
    } catch (_) {
      throw const MiniMaxHttpException('network_unavailable');
    } finally {
      client.close(force: true);
    }
  }

  Future<MiniMaxReply> send(
    MiniMaxEndpoint endpoint, {
    required String accessToken,
    required String region,
    String? userId,
    bool Function()? isCurrent,
  }) async {
    final wire = buildMiniMaxRequest(
      endpoint,
      accessToken: accessToken,
      region: region,
      userId: userId,
      version: version,
    );
    if (timeout <= Duration.zero || maxResponseBytes <= 0)
      throw const MiniMaxHttpException('invalid_configuration');
    HttpClient? client;
    try {
      client = _clientFactory();
      client.connectionTimeout = timeout < const Duration(seconds: 10)
          ? timeout
          : const Duration(seconds: 10);
      client.autoUncompress = true;
      return await _sendOnce(client, wire, isCurrent).timeout(timeout);
    } on MiniMaxHttpException {
      rethrow;
    } catch (_) {
      throw const MiniMaxHttpException('network_unavailable');
    } finally {
      client?.close(force: true);
    }
  }

  Future<MiniMaxReply> _sendOnce(
    HttpClient client,
    MiniMaxWireRequest wire,
    bool Function()? isCurrent,
  ) async {
    if (isCurrent != null && !isCurrent())
      throw const MiniMaxHttpException('request_cancelled');
    final request = await client.openUrl(wire.method, wire.uri);
    // openUrl can wait on a connection. Recheck before applying credentials or
    // writing any bytes; there is no await between this check and close().
    if (isCurrent != null && !isCurrent())
      throw const MiniMaxHttpException('request_cancelled');
    request.followRedirects = false;
    request.maxRedirects = 0;
    request.persistentConnection = false;
    wire.headers.forEach((k, v) => request.headers.set(k, v));
    if (wire.body != null) request.add(utf8.encode(wire.body!));
    final response = await request.close();
    if (response.contentLength > maxResponseBytes)
      throw const MiniMaxHttpException('invalid_response');
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > maxResponseBytes)
        throw const MiniMaxHttpException('invalid_response');
      bytes.addAll(chunk);
    }
    Map<String, dynamic>? body;
    try {
      final value = jsonDecode(utf8.decode(bytes));
      if (value is Map<String, dynamic>)
        body = value;
      else if (response.statusCode >= 200 && response.statusCode < 300)
        throw const MiniMaxHttpException('invalid_response');
    } catch (_) {
      if (response.statusCode >= 200 && response.statusCode < 300)
        throw const MiniMaxHttpException('invalid_response');
    }
    return MiniMaxReply(response.statusCode, body);
  }
}

// MD5 is required by the upstream HTTP wire format, not used for password storage.
String miniMaxWireMd5(String value) {
  final bytes = utf8.encode(value).toList();
  final bits = bytes.length * 8;
  bytes.add(128);
  while (bytes.length % 64 != 56) {
    bytes.add(0);
  }
  for (var i = 0; i < 8; i++) {
    bytes.add((bits >> (8 * i)) & 255);
  }
  const shifts = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21];
  final constants = List.generate(
    64,
    (i) => (math.sin(i + 1).abs() * 4294967296).floor(),
  );
  var a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
  for (var off = 0; off < bytes.length; off += 64) {
    final words = List.generate(
      16,
      (i) =>
          bytes[off + i * 4] |
          (bytes[off + i * 4 + 1] << 8) |
          (bytes[off + i * 4 + 2] << 16) |
          (bytes[off + i * 4 + 3] << 24),
    );
    var a = a0, b = b0, c = c0, d = d0;
    for (var i = 0; i < 64; i++) {
      int f, g;
      if (i < 16) {
        f = (b & c) | ((~b) & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | ((~d) & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | (~d));
        g = (7 * i) % 16;
      }
      final sum = (a + f + constants[i] + words[g]) & 0xffffffff;
      final s = shifts[(i ~/ 16) * 4 + i % 4];
      final rotated = ((sum << s) | (sum >> (32 - s))) & 0xffffffff;
      a = d;
      d = c;
      c = b;
      b = (b + rotated) & 0xffffffff;
    }
    a0 = (a0 + a) & 0xffffffff;
    b0 = (b0 + b) & 0xffffffff;
    c0 = (c0 + c) & 0xffffffff;
    d0 = (d0 + d) & 0xffffffff;
  }
  return [a0, b0, c0, d0]
      .expand((w) => List.generate(4, (i) => (w >> (i * 8)) & 255))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

// Dart normalizes percent-escaped unreserved characters. The legacy signature
// covers the original form-encoded query, so HttpClient must send that query.
class _ExactQueryUri implements Uri {
  final Uri base;
  @override
  final String query;
  _ExactQueryUri(this.base, this.query);
  @override
  String toString() => '$base?$query';
  @override
  String get scheme => base.scheme;
  @override
  String get authority => base.authority;
  @override
  String get userInfo => base.userInfo;
  @override
  String get host => base.host;
  @override
  int get port => base.port;
  @override
  String get path => base.path;
  @override
  String get fragment => base.fragment;
  @override
  List<String> get pathSegments => base.pathSegments;
  @override
  Map<String, String> get queryParameters => Uri.splitQueryString(query);
  @override
  Map<String, List<String>> get queryParametersAll =>
      Uri.parse(toString()).queryParametersAll;
  @override
  bool get isAbsolute => base.isAbsolute;
  @override
  bool get hasScheme => base.hasScheme;
  @override
  bool get hasAuthority => base.hasAuthority;
  @override
  bool get hasPort => base.hasPort;
  @override
  bool get hasQuery => true;
  @override
  bool get hasFragment => base.hasFragment;
  @override
  bool get hasEmptyPath => base.hasEmptyPath;
  @override
  bool get hasAbsolutePath => base.hasAbsolutePath;
  @override
  String get origin => base.origin;
  @override
  bool isScheme(String value) => base.isScheme(value);
  @override
  String toFilePath({bool? windows}) =>
      Uri.parse(toString()).toFilePath(windows: windows);
  @override
  UriData? get data => null;
  @override
  int get hashCode => toString().hashCode;
  @override
  bool operator ==(Object other) =>
      other is _ExactQueryUri && other.toString() == toString();
  @override
  Uri replace({
    String? scheme,
    String? userInfo,
    String? host,
    int? port,
    String? path,
    Iterable<String>? pathSegments,
    String? query,
    Map<String, dynamic>? queryParameters,
    String? fragment,
  }) => Uri.parse(toString()).replace(
    scheme: scheme,
    userInfo: userInfo,
    host: host,
    port: port,
    path: path,
    pathSegments: pathSegments,
    query: query,
    queryParameters: queryParameters,
    fragment: fragment,
  );
  @override
  Uri removeFragment() => this;
  @override
  Uri resolve(String reference) => Uri.parse(toString()).resolve(reference);
  @override
  Uri resolveUri(Uri reference) => Uri.parse(toString()).resolveUri(reference);
  @override
  Uri normalizePath() => this;
}
