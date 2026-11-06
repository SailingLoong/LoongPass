import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../credit_summary.dart';
import 'reward_provider.dart';

// Protocol reference, dsh-providers-hub a5b3cd10dd, src/lobsterai*.ts.
class LobsterAIProvider implements RewardProvider {
  LobsterAIProvider({DateTime Function()? now}) : _now = now ?? DateTime.now;
  final DateTime Function() _now;

  @override
  String get id => 'lobsterai';
  @override
  String get label => 'LobsterAI';
  @override
  String get region => '中国版';
  @override
  String get regionCode => 'CN';
  @override
  RewardLoginKind get loginKind => RewardLoginKind.browser;
  @override
  Set<String> get hosts => const {
    'lobsterai-server.youdao.com',
    'api-overmind.youdao.com',
  };

  Future<String> _version(RewardTransport http) async {
    final data = _data(
      await http.send(
        'GET',
        Uri.https(
          'api-overmind.youdao.com',
          '/openapi/get/luna/hardware/lobsterai/prod/update',
        ),
        headers: _anonymous,
      ),
    );
    final version = _text(_map(data['value'])?['version']);
    if (version == null ||
        version.length > 64 ||
        !RegExp(r'^\d+(?:\.\d+)*(?:-[0-9A-Za-z.-]+)?$').hasMatch(version)) {
      throw const RewardFailure('invalid_response');
    }
    return version;
  }

  @override
  Future<RewardLogin> beginLogin(RewardTransport http, {String? phone}) async {
    final version = await _version(http);
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      return _LobsterLogin(http, server, version, _now);
    } on SocketException {
      throw const RewardFailure('network_unavailable');
    }
  }

  @override
  Future<RewardSession> refresh(
    RewardTransport http,
    RewardSession session,
  ) async {
    _auth(session);
    final expiry =
        _expiry(session.credentials) ??
        _tokenExpiry(
          session.credentials['access_token'] as String,
          null,
          _now(),
        );
    if (expiry == null ||
        expiry.isAfter(_now().add(const Duration(minutes: 1)))) {
      return session;
    }
    final credentials = session.credentials;
    final refresh = _text(credentials['refresh_token']);
    if (refresh == null ||
        [
          'uuid',
          'first_keyfrom',
          'latest_keyfrom',
        ].any((key) => _text(credentials[key]) == null)) {
      throw const RewardFailure('login_required');
    }
    final version = await _version(http);
    final data = _data(
      await http.send(
        'POST',
        _api('/api/auth/refresh'),
        headers: _anonymous,
        body: {
          'refreshToken': refresh,
          'firstKeyfrom': credentials['first_keyfrom'],
          'latestKeyfrom': credentials['latest_keyfrom'],
          'uuid': credentials['uuid'],
          'version': version,
          if (_text(credentials['user_id']) != null)
            'userId': credentials['user_id'],
        },
      ),
    );
    if (data.containsKey('user') &&
        _identity(_map(data['user'])) != session.identity) {
      throw const RewardFailure('identity_mismatch');
    }
    final access = _text(data['accessToken']);
    if (access == null) throw const RewardFailure('invalid_response');
    final next = Map<String, dynamic>.from(credentials)
      ..['access_token'] = access;
    final rotated = _text(data['refreshToken']);
    if (rotated != null) next['refresh_token'] = rotated;
    next.remove('expires_at');
    final expires = _tokenExpiry(access, data['expiresIn'], _now());
    if (expires != null)
      next['expires_at'] = expires.millisecondsSinceEpoch.toString();
    return RewardSession(
      identity: session.identity,
      label: session.label,
      credentials: next,
    );
  }

  @override
  Future<CreditSummary> credits(
    RewardTransport http,
    RewardSession session,
  ) async {
    final data = _data(
      await http.send(
        'GET',
        _api('/api/user/profile-summary'),
        headers: _auth(session),
      ),
    );
    final total = _number(data['totalCreditsRemaining']);
    final items = data['creditItems'];
    if (total == null && items is! List)
      throw const RewardFailure('invalid_response');
    final amounts = <DateTime, double>{};
    var unknown = 0.0;
    final now = _now().toUtc();
    if (items != null && items is! List)
      throw const RewardFailure('invalid_response');
    for (final item in (items as List? ?? const [])) {
      final record = _map(item),
          remaining = _number(_map(item)?['creditsRemaining']);
      if (record == null || remaining == null)
        throw const RewardFailure('invalid_response');
      if (remaining == 0) continue;
      final rawExpiry = _text(record['expiresAt']);
      // A timezone-free timestamp has unknown precision for this client.
      final expires =
          rawExpiry != null &&
              RegExp(r'(?:Z|[+-]\d{2}:?\d{2})$').hasMatch(rawExpiry)
          ? DateTime.tryParse(rawExpiry)?.toUtc()
          : null;
      if (expires == null) {
        unknown += remaining;
      } else if (expires.isAfter(now)) {
        amounts.update(
          expires,
          (old) => old + remaining,
          ifAbsent: () => remaining,
        );
      }
    }
    final expiring = amounts.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final datedTotal = amounts.values.fold(0.0, (sum, value) => sum + value);
    if (total != null && total + 0.000001 < datedTotal + unknown) {
      throw const RewardFailure('invalid_response');
    }
    return CreditSummary(
      total,
      total == null ? unknown : max(0, total - datedTotal),
      now,
      expiring.map((entry) => CreditExpiry(entry.key, entry.value)).toList(),
    );
  }

  @override
  Future<RewardOffer> inspect(
    RewardTransport http,
    RewardSession session,
    String day,
  ) async {
    final headers = _auth(session), version = await _version(http);
    final slot = _data(
      await http.send(
        'GET',
        _api('/api/client-activities/slot', {
          'placement': 'desktop_sidebar',
          'clientVersion': version,
          'containerApiVersion': '2',
          'platform': 'win32',
        }),
        headers: headers,
      ),
    );
    final state = _text(slot['slotState']);
    if (state == null) throw const RewardFailure('invalid_response');
    if (state != 'available') return RewardOffer(RewardState.unavailable);
    final activity = _map(slot['activity']);
    final code = _text(activity?['activityCode']);
    final revision = _number(activity?['configRevision']);
    if (code == null ||
        revision == null ||
        revision != revision.truncateToDouble()) {
      throw const RewardFailure('invalid_response');
    }
    final context = _data(
      await http.send(
        'GET',
        _activity(code, 'context', {
          'configRevision': revision.toInt().toString(),
        }),
        headers: headers,
      ),
    );
    final claimed = _map(context['state'])?['claimedToday'];
    final actions = context['actions'];
    if (claimed == true) return RewardOffer(RewardState.already);
    if (claimed is! bool ||
        actions is! List ||
        actions.any((entry) => entry is! String)) {
      throw const RewardFailure('invalid_response');
    }
    if (!actions.contains('check_in'))
      return RewardOffer(RewardState.unavailable);
    return RewardOffer(
      RewardState.available,
      data: {
        'day': day,
        'identity': session.identity,
        'activityCode': code,
        'configRevision': revision.toInt(),
        'idempotencyKey': _uuid(),
      },
    );
  }

  @override
  Future<RewardResult> claim(
    RewardTransport http,
    RewardSession session,
    RewardOffer offer,
    String day,
  ) async {
    if (day != rewardDay(_now()))
      throw const RewardRejected('activity_changed');
    final code = _text(offer.data['activityCode']);
    if (offer.state != RewardState.available ||
        offer.data['day'] != day ||
        offer.data['identity'] != session.identity ||
        code == null ||
        offer.data['configRevision'] is! int ||
        _text(offer.data['idempotencyKey']) == null) {
      throw const RewardRejected('invalid_offer');
    }
    final data = _data(
      await http.send(
        'POST',
        _activity(code, 'actions/check_in'),
        headers: _auth(session),
        body: {
          'configRevision': offer.data['configRevision'],
          'idempotencyKey': offer.data['idempotencyKey'],
          'payload': <String, dynamic>{},
        },
      ),
    );
    final result = _map(data['result']);
    if (result == null) throw const RewardFailure('invalid_response');
    double? amount;
    for (final key in ['creditsGranted', 'rewardCredits', 'credits']) {
      if (result.containsKey(key)) {
        amount = _number(result[key]);
        if (amount == null) throw const RewardFailure('invalid_response');
        break;
      }
    }
    return RewardResult(RewardState.claimed, amount: amount);
  }
}

const _anonymous = {
  'Accept': 'application/json',
  'Content-Type': 'application/json',
  'User-Agent': 'LobsterAI/0.1.0',
};

Uri _api(String path, [Map<String, String>? query]) =>
    Uri.https('lobsterai-server.youdao.com', path, query);
Uri _activity(String code, String action, [Map<String, String>? query]) => Uri(
  scheme: 'https',
  host: 'lobsterai-server.youdao.com',
  pathSegments: ['api', 'client-activities', code, ...action.split('/')],
  queryParameters: query,
);
Map<String, dynamic>? _map(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) return null;
  return Map<String, dynamic>.from(value);
}

String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;
double? _number(Object? value) {
  final number = value is num
      ? value.toDouble()
      : value is String
      ? double.tryParse(value)
      : null;
  return number != null && number.isFinite && number >= 0 ? number : null;
}

Map<String, dynamic> _data(RewardReply reply) {
  if (reply.status == 408 || reply.status >= 500 || reply.status == 429)
    throw const RewardFailure('network_unavailable');
  final code = _number(reply.body['code']);
  final businessResponse = reply.status == 200 || reply.status == 400;
  if (reply.status == 401 ||
      reply.status == 403 ||
      businessResponse && [40100, 40101].contains(code)) {
    throw const RewardRejected('login_required');
  }
  // The activity protocol defines 40001 as an ended-activity rejection.
  if (businessResponse && code == 40001)
    throw const RewardRejected('request_rejected');
  if (reply.status < 200 || reply.status >= 300 || code != 0) {
    throw const RewardFailure('request_rejected');
  }
  return _map(reply.body['data']) ??
      (throw const RewardFailure('invalid_response'));
}

Map<String, String> _auth(RewardSession session) {
  final token = _text(session.credentials['access_token']);
  if (_text(session.identity) == null || token == null)
    throw const RewardRejected('login_required');
  return {..._anonymous, 'Authorization': 'Bearer $token'};
}

String? _identity(Map<String, dynamic>? user) {
  for (final field in ['id', 'userId', 'yid']) {
    final value = _text(user?[field]);
    if (value != null) return value;
  }
  return null;
}

DateTime? _expiry(Map<String, dynamic> credentials) {
  final raw = credentials['expires_at'];
  final number = _number(raw);
  if (number != null) {
    return DateTime.fromMillisecondsSinceEpoch(
      (number > 1000000000000 ? number : number * 1000).round(),
      isUtc: true,
    );
  }
  return raw is String ? DateTime.tryParse(raw)?.toUtc() : null;
}

DateTime? _tokenExpiry(String token, Object? expiresIn, DateTime now) {
  final seconds = _number(expiresIn);
  if (seconds != null && seconds > 0)
    return now.toUtc().add(Duration(milliseconds: (seconds * 1000).round()));
  try {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1]))),
    );
    final exp = _number(_map(payload)?['exp']);
    return exp == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            (exp * 1000).round(),
            isUtc: true,
          );
  } catch (_) {
    return null;
  }
}

String _uuid() {
  final random = Random.secure(), bytes = List.generate(16, (_) => 0);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = random.nextInt(256);
  }
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class _LobsterLogin implements RewardLogin {
  _LobsterLogin(this.http, this.server, this.version, this.now)
    : deadline = now().add(const Duration(minutes: 10)),
      firstKeyfrom = now().millisecondsSinceEpoch.toString() {
    _timer = Timer(const Duration(minutes: 10), _close);
    server.listen(
      _callback,
      onError: (Object error) {
        _close();
      },
    );
  }
  final RewardTransport http;
  final HttpServer server;
  final String version, firstKeyfrom;
  final DateTime Function() now;
  final DateTime deadline;
  final String state = _uuid(), uuid = _uuid();
  late final Timer _timer;
  bool _cancelled = false;
  String? _code;
  Map<String, dynamic>? _authorization;
  RewardSession? _session;
  Future<RewardSession?>? _polling;

  @override
  Uri get url => Uri.parse(
    'https://lobsterai.youdao.com/portal#/login?${Uri(queryParameters: {'source': 'electron', 'redirect_uri': 'http://127.0.0.1:${server.port}/auth/callback', 'state': state}).query}',
  );

  void _close() {
    _timer.cancel();
    unawaited(server.close(force: true));
  }

  void _active() {
    if (_cancelled) throw const RewardFailure('cancelled');
    if (_session == null && !now().isBefore(deadline)) {
      _close();
      throw const RewardFailure('authorization_expired');
    }
  }

  Future<void> _callback(HttpRequest request) async {
    var status = 400;
    if (request.uri.path != '/auth/callback') {
      status = 404;
    } else if (request.method != 'GET') {
      status = 405;
    } else if (!_cancelled &&
        now().isBefore(deadline) &&
        _code == null &&
        request.headers.value('host') == '127.0.0.1:${server.port}' &&
        request.uri.queryParametersAll['state']?.length == 1 &&
        request.uri.queryParameters['state'] == state &&
        request.uri.queryParametersAll['code']?.length == 1 &&
        _text(request.uri.queryParameters['code']) != null) {
      _code = request.uri.queryParameters['code'];
      status = 200;
    }
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.text;
    request.response.write(
      status == 200
          ? 'Authorization received. Return to LoongPass.'
          : 'Authorization callback rejected.',
    );
    await request.response.close();
    if (status == 200) unawaited(server.close(force: true));
  }

  @override
  Future<RewardSession?> poll({String? verificationCode}) async {
    _active();
    if (_session != null) return _session;
    if (_code == null) return null;
    if (_polling != null) return _polling;
    final pending = _exchange();
    _polling = pending;
    try {
      return await pending;
    } finally {
      _polling = null;
    }
  }

  Future<RewardSession> _exchange() async {
    final latest = now().millisecondsSinceEpoch.toString();
    final data =
        _authorization ??
        _data(
          await http.send(
            'POST',
            _api('/api/auth/exchange'),
            headers: _anonymous,
            body: {
              'authCode': _code,
              'firstKeyfrom': firstKeyfrom,
              'latestKeyfrom': latest,
              'uuid': uuid,
              'version': version,
            },
          ),
        );
    _active();
    _authorization = data;
    final user = _map(data['user']), identity = _identity(_map(data['user']));
    final access = _text(data['accessToken']);
    if (identity == null) throw const RewardFailure('invalid_identity');
    if (access == null) throw const RewardFailure('invalid_response');
    final expires = _tokenExpiry(access, data['expiresIn'], now());
    final nickname = _text(user?['nickname']) ?? 'LobsterAI 账号';
    _session = RewardSession(
      identity: identity,
      label: nickname.replaceAllMapped(
        RegExp(r'(?:\+?86[- ]?)?1[\d*]{10}'),
        (match) => '尾号 ${match[0]!.substring(match[0]!.length - 2)}',
      ),
      credentials: {
        'access_token': access,
        'refresh_token': _text(data['refreshToken']) ?? '',
        'uuid': uuid,
        'first_keyfrom': firstKeyfrom,
        'latest_keyfrom': latest,
        if (_text(user?['userId']) ?? _text(user?['yid'])
            case final String userId)
          'user_id': userId,
        if (expires != null)
          'expires_at': expires.millisecondsSinceEpoch.toString(),
      },
    );
    _close();
    return _session!;
  }

  @override
  void cancel() {
    _cancelled = true;
    _session = null;
    _code = null;
    _authorization = null;
    _close();
  }
}
