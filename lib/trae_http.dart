import 'dart:async';
import 'dart:convert';
import 'dart:io';

class TraeFailure implements Exception {
  final String code;
  const TraeFailure(this.code);
  @override
  String toString() => 'TRAE: $code';
}

class TraeReply {
  final int status;
  final Map<String, dynamic> body;
  final int? serverMs;
  TraeReply(this.status, this.body, [this.serverMs]);
  @override
  String toString() => 'TraeReply(redacted)';
}

abstract interface class TraeTransport {
  Future<TraeReply> post(
    String path,
    Map<String, dynamic> body, {
    String? token,
    Map<String, dynamic>? device,
    bool Function()? isCurrent,
  });
}

class TraeHttp implements TraeTransport {
  static const profile = '/cloudide/api/v3/trae/GetUserInfo';
  static const exchange = '/trae/api/v3/oauth/ExchangeToken';
  static const status = '/trae/api/v2/ug/checkin_credits/status';
  static const claim = '/trae/api/v2/ug/checkin_credits/claim';
  static const credits = '/trae/api/v2/pay/ide_user_ent_usage';
  @override
  Future<TraeReply> post(
    String path,
    Map<String, dynamic> body, {
    String? token,
    Map<String, dynamic>? device,
    bool Function()? isCurrent,
  }) async {
    if (!{profile, exchange, status, claim, credits}.contains(path))
      throw const TraeFailure('invalid_endpoint');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      return await (() async {
        if (isCurrent?.call() == false) throw const TraeFailure('cancelled');
        final req = await client.postUrl(Uri.https('api.trae.cn', path));
        if (isCurrent?.call() == false) throw const TraeFailure('cancelled');
        req.followRedirects = false;
        req.headers.contentType = ContentType.json;
        req.headers.set('Accept', 'application/json');
        if (path == profile || path == exchange) {
          req.headers.set('x-cloudide-token', token ?? '');
        } else if (token != null) {
          req.headers.set('Authorization', 'Cloud-IDE-JWT $token');
        }
        if (device != null) {
          for (final entry in {
            'x-device-id': 'DeviceID',
            'x-device-brand': 'DeviceModel',
            'x-device-type': 'OSInfo',
            'x-os-version': 'OSVersion',
            'x-app-version': 'ClientVersion',
          }.entries) {
            final value = device[entry.value];
            if (value is String && value.isNotEmpty)
              req.headers.set(entry.key, value);
          }
        }
        req.write(jsonEncode(body));
        final response = await req.close();
        if (response.isRedirect ||
            response.statusCode >= 300 && response.statusCode < 400)
          throw const TraeFailure('redirect_rejected');
        final bytes = <int>[];
        await for (final part in response) {
          if (bytes.length + part.length > 2 * 1024 * 1024)
            throw const TraeFailure('invalid_response');
          bytes.addAll(part);
        }
        Map<String, dynamic> decoded = {};
        try {
          final value = jsonDecode(utf8.decode(bytes));
          if (value is Map<String, dynamic>) decoded = value;
        } catch (_) {}
        int? server;
        try {
          server = HttpDate.parse(
            response.headers.value('date') ?? '',
          ).millisecondsSinceEpoch;
        } catch (_) {}
        return TraeReply(response.statusCode, decoded, server);
      })().timeout(const Duration(seconds: 30));
    } on TraeFailure {
      rethrow;
    } catch (_) {
      throw const TraeFailure('network_unavailable');
    } finally {
      client.close(force: true);
    }
  }
}
