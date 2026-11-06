// Protocol adapted from SailingLoong/LoongPort official.rs/claim_protocol.rs
// (MIT). See ZCODE-ACTIVITIES.md for provenance and live acceptance.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ZcodeFailure implements Exception {
  final String code;
  final int? httpStatus, serviceCode;
  const ZcodeFailure(this.code, {this.httpStatus, this.serviceCode});
  @override
  String toString() => 'ZcodeFailure($code)';
}

bool zcodeText(Object? v, [int max = 256]) =>
    v is String &&
    v.isNotEmpty &&
    v.trim() == v &&
    v.length <= max &&
    !v.runes.any((c) => c < 32 || (c >= 127 && c <= 159));

Map<String, String> zcodeContext(Map<String, dynamic> value) {
  const keys = ['version', 'platform', 'deviceMid', 'language', 'timezone'];
  if (keys.any((k) => !zcodeText(value[k], 128)) ||
      !RegExp(
        r'^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][a-zA-Z0-9.-]+)?$',
      ).hasMatch(value['version']) ||
      !{'darwin-arm64', 'darwin-x64'}.contains(value['platform']) ||
      !RegExp(
        r'^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$',
      ).hasMatch(value['deviceMid'])) {
    throw const ZcodeFailure('device_required');
  }
  return {for (final key in keys) key: value[key] as String};
}

class ZcodeRequest {
  final String path, token;
  final Map<String, String> context;
  final Map<String, dynamic>? body;
  final ZcodeVerification? verification;
  ZcodeRequest(
    this.path,
    this.token,
    this.context, [
    this.body,
    this.verification,
  ]);
  @override
  String toString() => 'ZcodeRequest([redacted])';
}

class ZcodeReply {
  final int status;
  final Map<String, dynamic> body;
  const ZcodeReply(this.status, this.body);
  @override
  String toString() => 'ZcodeReply($status, [redacted])';
}

abstract interface class ZcodeTransport {
  Future<ZcodeReply> send(ZcodeRequest request, {bool Function()? isCurrent});
}

class ZcodeHttp implements ZcodeTransport {
  @override
  Future<ZcodeReply> send(ZcodeRequest r, {bool Function()? isCurrent}) async {
    final allowed = {
      ZcodeApi.initPath,
      ZcodeApi.balancePath,
      ZcodeApi.previewPath,
      ZcodeApi.marketingPath,
      ZcodeApi.claimPath,
      ZcodeApi.configPath,
    };
    if (!allowed.contains(r.path) &&
        !(r.path.startsWith(ZcodeApi.pollPrefix) &&
            RegExp(
              r'^[a-zA-Z0-9_-]{1,256}$',
            ).hasMatch(r.path.substring(ZcodeApi.pollPrefix.length)))) {
      throw const ZcodeFailure('invalid_request');
    }
    if (!zcodeText(r.token, 16384))
      throw const ZcodeFailure('authorization_required');
    final context = zcodeContext(r.context);
    if (r.verification != null && r.path != ZcodeApi.claimPath)
      throw const ZcodeFailure('invalid_request');
    final query = <String, String>{
      if (r.path == ZcodeApi.balancePath || r.path == ZcodeApi.previewPath)
        'app_version': context['version']!,
      if (r.path == ZcodeApi.previewPath) 'platform': context['platform']!,
      if (r.path == ZcodeApi.marketingPath) 'seq': '0',
    };
    final post = r.path == ZcodeApi.initPath || r.path == ZcodeApi.claimPath;
    if (post != (r.body != null)) throw const ZcodeFailure('invalid_request');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    void check() {
      if (isCurrent?.call() == false) throw const ZcodeFailure('cancelled');
    }

    try {
      return await (() async {
        check();
        final req = await client.openUrl(
          post ? 'POST' : 'GET',
          Uri.https('zcode.z.ai', r.path, query.isEmpty ? null : query),
        );
        req.followRedirects = false;
        final headers = {
          'Authorization': 'Bearer ${r.token}',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'HTTP-Referer': 'https://zcode.z.ai',
          'X-Title': 'LoongPass',
          'User-Agent': 'LoongPass',
          'X-Release-Channel': 'production',
          'X-OS-Category': 'macos',
          'X-ZCode-App-Version': context['version']!,
          'X-Platform': context['platform']!,
          'X-Device-Mid': context['deviceMid']!,
          'X-Client-Language': context['language']!,
          'X-Client-Timezone': context['timezone']!,
          if (r.verification != null) ...r.verification!.headers,
        };
        headers.forEach(req.headers.set);
        check();
        if (r.body != null) req.write(jsonEncode(r.body));
        final response = await req.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          check();
          if (bytes.length + chunk.length > 1024 * 1024)
            throw const ZcodeFailure('invalid_response');
          bytes.addAll(chunk);
        }
        check();
        Map<String, dynamic> decoded;
        try {
          final value = jsonDecode(utf8.decode(bytes));
          if (value is! Map<String, dynamic>) throw const FormatException();
          decoded = value;
        } catch (_) {
          throw ZcodeFailure(
            {401, 403}.contains(response.statusCode)
                ? 'authorization_required'
                : 'invalid_response',
            httpStatus: response.statusCode,
          );
        }
        // No response strings, URLs or credential values escape as diagnostics.
        return ZcodeReply(response.statusCode, decoded);
      })().timeout(const Duration(seconds: 25));
    } on ZcodeFailure {
      rethrow;
    } catch (_) {
      throw const ZcodeFailure('network_unavailable');
    } finally {
      client.close(force: true);
    }
  }
}

class ZcodeApi {
  static const initPath = '/api/v1/oauth/cli/init';
  static const pollPrefix = '/api/v1/oauth/cli/poll/';
  static const balancePath = '/api/v1/zcode-plan/billing/balance';
  static const previewPath = '/api/v1/zcode-plan/billing/preview';
  static const claimPath = '/api/v1/zcode-plan/billing/claim';
  static const marketingPath = '/api/v1/marketing/touch';
  static const configPath = '/api/v1/client/configs';
  final ZcodeTransport transport;
  ZcodeApi(this.transport);
  Future<Map<String, dynamic>> request(
    String path,
    String token,
    Map<String, String> context, {
    Map<String, dynamic>? body,
    ZcodeVerification? verification,
    bool Function()? isCurrent,
  }) async {
    if (isCurrent?.call() == false) throw const ZcodeFailure('cancelled');
    final result = await transport.send(
      ZcodeRequest(path, token, context, body, verification),
      isCurrent: isCurrent,
    );
    if (isCurrent?.call() == false) throw const ZcodeFailure('cancelled');
    if (result.status == 401 ||
        result.status == 403 ||
        {401, 403}.contains(zcodeCode(result.body))) {
      throw ZcodeFailure(
        'authorization_required',
        httpStatus: result.status,
        serviceCode: zcodeCode(result.body),
      );
    }
    if (result.status != 200)
      throw ZcodeFailure(
        'service_unavailable',
        httpStatus: result.status,
        serviceCode: zcodeCode(result.body),
      );
    return result.body;
  }
}

class ZcodeCaptchaConfig {
  final Map<String, String> values;
  ZcodeCaptchaConfig._(this.values);
  factory ZcodeCaptchaConfig.parse(Map<String, dynamic> reply) {
    final configs = zcodeData(reply)['configs'];
    final c = configs is Map ? configs['captcha'] : null;
    if (c is! Map || c['enabled'] != true)
      throw const ZcodeFailure('verification_unavailable');
    final values = <String, String>{};
    for (final key in ['region', 'prefix', 'sceneId']) {
      if (c[key] is! String ||
          !RegExp(r'^[a-zA-Z0-9._-]{1,128}$').hasMatch(c[key]))
        throw const ZcodeFailure('verification_unavailable');
      values[key] = c[key];
    }
    return ZcodeCaptchaConfig._(Map.unmodifiable(values));
  }
}

class ZcodeVerification {
  final String param, region;
  ZcodeVerification(this.param, this.region) {
    if (!zcodeText(param, 16384) ||
        !RegExp(r'^[a-zA-Z0-9._-]{1,128}$').hasMatch(region))
      throw const ZcodeFailure('verification_unavailable');
  }
  Map<String, String> get headers => {
    'X-Aliyun-Captcha-Verify-Param': param,
    'X-Aliyun-Captcha-Verify-Region': region,
  };
  @override
  String toString() => 'ZcodeVerification([redacted])';
}

int? zcodeCode(Map<String, dynamic> body) {
  final value = body['code'];
  return value is int
      ? value
      : value is String && RegExp(r'^\d+$').hasMatch(value)
      ? int.tryParse(value)
      : null;
}

Map<String, dynamic> zcodeData(Map<String, dynamic> body) {
  if (!{0, 200}.contains(zcodeCode(body)) ||
      body['data'] is! Map<String, dynamic>) {
    throw const ZcodeFailure('invalid_response');
  }
  return body['data'] as Map<String, dynamic>;
}
