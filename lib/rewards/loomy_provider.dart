import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../credit_summary.dart';
import 'reward_provider.dart';

// Protocol reference, dsh-providers-hub a5b3cd10dd, src/loomy-{oauth,sign,credits}.ts.
class LoomyProvider implements RewardProvider {
  LoomyProvider({DateTime Function()? now}) : _now = now ?? DateTime.now;
  final DateTime Function() _now;

  @override
  String get id => 'loomy';
  @override
  String get label => 'Loomy';
  @override
  String get region => '中国版';
  @override
  String get regionCode => 'CN';
  @override
  RewardLoginKind get loginKind => RewardLoginKind.sms;
  @override
  Set<String> get hosts => const {'account.xfinfr.com', 'loomyad.xunfei.cn'};

  @override
  Future<RewardLogin> beginLogin(RewardTransport http, {String? phone}) async {
    if (phone == null || !RegExp(r'^1\d{10}$').hasMatch(phone)) {
      throw const RewardFailure('invalid_phone');
    }
    final deadline = _now().add(const Duration(seconds: 300));
    final data = await _account(http, '/login/phone/sendMsgCode', {
      'ccode': '86',
      'phone': phone,
      'expire': 300,
    }, _now());
    final message = _text(data['msgid']);
    if (message == null) throw const RewardFailure('invalid_response');
    return _LoomyLogin(http, phone, message, deadline, _now);
  }

  @override
  Future<RewardSession> refresh(
    RewardTransport http,
    RewardSession session,
  ) async {
    _auth(session);
    // Older entries estimated this date from the requested TTL. Official
    // authenticated responses determine whether the saved session is valid.
    if (!session.credentials.containsKey('expires_at')) return session;
    final credentials = Map<String, dynamic>.from(session.credentials)
      ..remove('expires_at');
    return RewardSession(
      identity: session.identity,
      label: session.label,
      credentials: credentials,
    );
  }

  Future<Map<String, dynamic>> _records(
    RewardTransport http,
    RewardSession session,
  ) async {
    final payload = _data(
      await http.send(
        'GET',
        _business('/api/v2/points/records', {
          'pageNo': '1',
          'pageSize': '1',
          'direction': 'debit',
          'granularity': 'chat',
        }),
        headers: _auth(session),
      ),
    );
    final data = Map<String, dynamic>.from(
      payload['data'] is Map ? payload['data'] as Map : payload,
    );
    if (data.containsKey('dailyRemainingPoints')) {
      final remaining = _number(data['dailyRemainingPoints']);
      if (remaining == null ||
          data.containsKey('dailyBalance') &&
              _number(data['dailyBalance']) != remaining)
        throw const RewardFailure('invalid_response');
      data['dailyBalance'] = remaining;
    }
    if (_number(data['balance']) == null &&
        _number(data['dailyBalance']) == null) {
      throw const RewardFailure('invalid_response');
    }
    for (final key in ['balance', 'dailyBalance', 'availableBalance']) {
      if (data.containsKey(key) && _number(data[key]) == null) {
        throw const RewardFailure('invalid_response');
      }
    }
    return data;
  }

  @override
  Future<CreditSummary> credits(
    RewardTransport http,
    RewardSession session,
  ) async {
    final data = await _records(http, session), now = _now().toUtc();
    final permanent = _number(data['balance']),
        daily = _number(data['dailyBalance']);
    final total =
        _number(data['availableBalance']) ??
        (permanent != null && daily != null ? permanent + daily : null);
    if (total != null && total + 0.000001 < (permanent ?? 0) + (daily ?? 0)) {
      throw const RewardFailure('invalid_response');
    }
    final cycle = _cycle(data['dailyCycleDate']);
    if (daily != null &&
        daily > 0 &&
        cycle != null &&
        cycle != rewardDay(now)) {
      throw const RewardFailure('invalid_response');
    }
    return CreditSummary(
      total,
      total == null ? permanent ?? 0 : total - (daily ?? 0),
      now,
      [
        if (daily != null && daily > 0)
          CreditExpiry(_dayEnd(cycle ?? rewardDay(now)), daily),
      ],
    );
  }

  @override
  Future<RewardOffer> inspect(
    RewardTransport http,
    RewardSession session,
    String day,
  ) async {
    final data = await _records(http, session);
    final cycle = _cycle(data['dailyCycleDate']);
    if (cycle != null && cycle.compareTo(day) > 0)
      throw const RewardFailure('invalid_response');
    if (cycle == day && _number(data['dailyBalance']) != null) {
      return RewardOffer(RewardState.already);
    }
    return RewardOffer(
      RewardState.available,
      data: {'day': day, 'identity': session.identity},
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
    if (offer.state != RewardState.available ||
        offer.data['day'] != day ||
        offer.data['identity'] != session.identity) {
      throw const RewardRejected('invalid_offer');
    }
    final data = _data(
      await http.send(
        'POST',
        _business('/api/v1/points/first-login'),
        headers: _auth(session),
        body: <String, dynamic>{},
      ),
    );
    final processed = data['alreadyProcessed'];
    if (processed is! bool || _cycle(data['dailyCycleDate']) != day) {
      throw const RewardFailure('invalid_response');
    }
    if (processed) return const RewardResult(RewardState.already);
    final quota = _number(data['dailyQuota']),
        daily = _number(data['dailyBalance']);
    final consumed = _number(data['dailyConsumed']);
    if (quota == null ||
        daily == null ||
        consumed == null ||
        (daily + consumed - quota).abs() > 0.000001) {
      throw const RewardFailure('invalid_response');
    }
    // The response reports the pool's current state, not a newly credited delta.
    return const RewardResult(RewardState.claimed);
  }
}

Uri _business(String path, [Map<String, String>? query]) =>
    Uri.https('loomyad.xunfei.cn', path, query);
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
  final code = reply.body['code'];
  final businessResponse = reply.status == 200 || reply.status == 400;
  if (reply.status == 401 ||
      reply.status == 403 ||
      businessResponse && {'100002', '020002'}.contains(code)) {
    throw const RewardRejected('login_required');
  }
  // 100001 is the source-defined business parameter rejection.
  if (businessResponse && code == '100001')
    throw const RewardRejected('request_rejected');
  if (reply.status < 200 || reply.status >= 300 || code != '000000') {
    throw const RewardFailure('request_rejected');
  }
  return _map(reply.body['data']) ??
      (throw const RewardFailure('invalid_response'));
}

Map<String, String> _auth(RewardSession session) {
  final token = _text(session.credentials['access_token']);
  if (_text(session.identity) == null || token == null)
    throw const RewardRejected('login_required');
  if (_text(session.credentials['userid']) != session.identity) {
    throw const RewardRejected('identity_mismatch');
  }
  return {'Accept': 'application/json', 'token': token};
}

String? _cycle(Object? value) {
  if (value == null) return null;
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw const RewardFailure('invalid_response');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null || parsed.toIso8601String().substring(0, 10) != value) {
    throw const RewardFailure('invalid_response');
  }
  return value;
}

DateTime _dayEnd(String day) =>
    DateTime.parse('${day}T00:00:00+08:00').add(const Duration(days: 1));

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

Future<Map<String, dynamic>> _account(
  RewardTransport http,
  String path,
  Map<String, dynamic> param,
  DateTime now,
) async {
  // Published desktop client keys from src/loomy-product.ts, not user secrets.
  const key = '2thryby66wxi53sk', secret = 'zsak6eadrbawz683wf5r3m2snrwj868r';
  final body = jsonEncode({
    'base': {
      'appid': 'GM3LOOMY',
      'modelid': 'Web',
      'version': '1.0.0',
      'devid': 'web',
      'ua': 'Loomy|Desktop|Electron|macOS',
      'traceid': _uuid().replaceAll('-', ''),
    },
    'param': param,
  });
  final digest = base64.encode(md5.convert(utf8.encode(body)).bytes);
  final date = HttpDate.format(now.toUtc()), nonce = _uuid();
  final canonical = [
    'POST',
    path,
    '',
    digest,
    'application/json',
    date,
    nonce,
    '',
    '',
  ].join('\n');
  final signature = base64.encode(
    Hmac(sha1, utf8.encode(secret)).convert(utf8.encode(canonical)).bytes,
  );
  return _data(
    await http.send(
      'POST',
      Uri.https('account.xfinfr.com', path),
      headers: {
        'Authorization': 'account $key:$signature',
        'Date': date,
        'Nonce': nonce,
        'Content-Type': 'application/json',
        'Content-MD5': digest,
      },
      body: body,
    ),
  );
}

class _LoomyLogin implements RewardLogin {
  _LoomyLogin(this.http, this.phone, this.message, this.deadline, this.now);
  final RewardTransport http;
  final String phone, message;
  final DateTime deadline;
  final DateTime Function() now;
  bool _cancelled = false;
  String? _code;
  Map<String, dynamic>? _authorization;
  RewardSession? _session;
  Future<RewardSession?>? _polling;

  @override
  Uri? get url => null;
  void _active() {
    if (_cancelled) throw const RewardFailure('cancelled');
    if (_session == null && !now().isBefore(deadline))
      throw const RewardFailure('authorization_expired');
  }

  @override
  Future<RewardSession?> poll({String? verificationCode}) async {
    _active();
    if (_session != null) return _session;
    if (verificationCode != null) {
      if (!RegExp(r'^\d{6}$').hasMatch(verificationCode))
        throw const RewardFailure('invalid_verification_code');
      _code = verificationCode;
    }
    if (_code == null) return null;
    if (_polling != null) return _polling;
    final pending = _complete(_code!);
    _polling = pending;
    try {
      return await pending;
    } finally {
      _polling = null;
    }
  }

  Future<RewardSession> _complete(String code) async {
    final started = now();
    final data =
        _authorization ??
        await _account(http, '/login/phone/checkCode', {
          'ccode': '86',
          'phone': phone,
          'mcode': code,
          'msgid': message,
          'expire': 1209600,
        }, started);
    _active();
    _authorization = data;
    final token = _text(data['session']), identity = _text(data['userid']);
    if (identity == null) throw const RewardFailure('invalid_identity');
    if (token == null) throw const RewardFailure('invalid_response');
    _session = RewardSession(
      identity: identity,
      label: 'Loomy · 尾号 ${phone.substring(9)}',
      credentials: {'access_token': token, 'userid': identity},
    );
    return _session!;
  }

  @override
  void cancel() {
    _cancelled = true;
    _session = null;
    _code = null;
    _authorization = null;
  }
}
