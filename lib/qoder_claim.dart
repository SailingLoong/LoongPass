// Protocol port from LoongPort qoder_daily/{contract,http,clock}.rs at
// 9e1b7e574e1ca923d8ee5aab3cd7ede16a8872b6 (MIT; see LICENSE).
// Copyright (c) 2025 Jason Young; Copyright (c) 2026 SailingLoong.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _origin = 'https://openapi.qoder.sh';
const _campaigns = '/sash/api/v1/me/campaigns';
const _maxBody = 1024 * 1024;

class QoderFailure implements Exception {
  final String code;
  const QoderFailure(this.code);
  @override
  String toString() => code;
}

/// Binding facts from the future authenticated adapter, NOT authentication proof.
/// No credentials or generated device identifiers are accepted by this module.
class QoderIdentity {
  final String providerId, uid, generation, region;
  const QoderIdentity(
    this.providerId,
    this.uid,
    this.generation, {
    this.region = 'international',
  });
  bool _matches(QoderIdentity other) =>
      providerId == other.providerId &&
      uid == other.uid &&
      generation == other.generation &&
      region == other.region;
  bool get _valid =>
      providerId.trim().isNotEmpty &&
      uid.trim().isNotEmpty &&
      generation.trim().isNotEmpty &&
      uid.length <= 512;
}

/// Adapter must supply identity, final URI, headers and bounded body from the
/// SAME authenticated response. Constructing this object proves none of that.
/// Normal TLS, no redirects/retries, official device provenance, network body
/// limits and credential revocation are external adapter responsibilities.
class QoderReply {
  final QoderIdentity identity;
  final Uri uri;
  final int status;
  final String body;
  final Map<String, List<String>> headers;
  final Duration requestElapsed;
  final Stopwatch _age = Stopwatch()..start();
  QoderReply({
    required this.identity,
    required this.uri,
    required this.status,
    required this.body,
    Map<String, List<String>> headers = const {},
    this.requestElapsed = Duration.zero,
  }) : headers = Map.unmodifiable({
         for (final e in headers.entries)
           e.key: List<String>.unmodifiable(e.value),
       });

  Map<String, dynamic>? get _json => decodeQoderObject(body);
}

/// Fixed-origin request descriptor. The authenticated adapter adds credentials;
/// this core never sends or logs them and has no production transport yet.
class QoderRequest {
  final String method;
  final Uri uri;
  final String? body;
  const QoderRequest._(this.method, this.uri, this.body);
}

enum QoderOutcome {
  newlyClaimed,
  alreadyClaimed,
  claimedDeltaUnknown,
  unknown,
  conflict,
  verificationRequired,
  rateLimited;

  int? get addedCredits => switch (this) {
    QoderOutcome.newlyClaimed => 100,
    QoderOutcome.alreadyClaimed => 0,
    _ => null,
  };
}

/// One campaign operation. The owner must atomically persist the intent BEFORE
/// granting a POST and resume it after restart. The callback is a required seam,
/// not an implemented database or global/cross-process lock. UI remains disabled.
class QoderClaimOperation {
  final QoderIdentity _identity;
  final String _campaignId, _campaignKey;
  final int _start, _end;
  final QoderReply? _listing;
  final int? _serverTime;
  bool _attempted;
  bool _busy = false;
  QoderClaimOperation._(
    this._identity,
    this._campaignId,
    this._campaignKey,
    this._start,
    this._end,
    this._listing,
    this._serverTime,
    this._attempted,
  );

  factory QoderClaimOperation.prepare(QoderReply listing) =>
      QoderClaimOperation._fromListing(listing, 'CLAIMABLE');

  /// A validated, current server row may report an already settled operation.
  /// This reads status only; it never changes the saved intent or permits POST.
  static bool matchesClaimedListing(
    QoderReply listing,
    Map<String, Object?> record,
  ) {
    try {
      final current = QoderClaimOperation._fromListing(
        listing,
        'CLAIMED',
      ).intent;
      return [
        'uid',
        'region',
        'campaignId',
        'campaignKey',
        'startAt',
        'endAt',
      ].every((key) => current[key] == record[key]);
    } on QoderFailure catch (error) {
      if (error.code == 'NoEligibleCampaign') return false;
      rethrow;
    }
  }

  factory QoderClaimOperation._fromListing(QoderReply listing, String status) {
    final id = listing.identity;
    if (id.region != 'international')
      throw const QoderFailure('UnsupportedRegion');
    if (!id._valid) throw const QoderFailure('IdentityMismatch');
    if (listing.status != 200 ||
        !_expectedUri(listing.uri, '$_campaigns?clientType=10')) {
      throw const QoderFailure('InvalidResponse');
    }
    final root = listing._json;
    if (root == null) throw const QoderFailure('InvalidResponse');
    if (!_consistentIdentity(root, id.uid))
      throw const QoderFailure('IdentityMismatch');
    final body = _envelope(root, 'campaigns');
    if (body == null || body['campaigns'] is! List)
      throw const QoderFailure('InvalidResponse');
    if (body['uid'] != id.uid) throw const QoderFailure('IdentityMismatch');
    final seconds = _serverDate(listing);
    final rows = body['campaigns'] as List;
    final counts = <String, int>{};
    for (final row in rows.whereType<Map>()) {
      final id = row['campaignId'];
      if (id is String) counts[id] = (counts[id] ?? 0) + 1;
    }
    final candidates = <Map>[];
    for (final row in rows.whereType<Map>()) {
      final campaign = row['campaignId'];
      final benefit = row['benefit'];
      final start = row['startAt'];
      final end = row['endAt'];
      if (campaign is! String ||
          !_safeId(campaign) ||
          row['campaignKey'] is! String ||
          (row['campaignKey'] as String).trim().isEmpty ||
          counts[campaign] != 1 ||
          row['actionType'] != 'CLAIM_BENEFIT' ||
          row['claimStatus'] != status ||
          benefit is! Map ||
          benefit['kind'] != 'CREDITS' ||
          benefit['amount'] is! int ||
          benefit['amount'] != 100 ||
          start is! int ||
          end is! int ||
          start < 0 ||
          start >= end ||
          seconds < start ||
          seconds >= end) {
        continue;
      }
      candidates.add(row);
    }
    if (candidates.isEmpty) throw const QoderFailure('NoEligibleCampaign');
    if (candidates.length != 1) throw const QoderFailure('AmbiguousTarget');
    final row = candidates.single;
    final op = QoderClaimOperation._(
      id,
      row['campaignId'] as String,
      row['campaignKey'] as String,
      row['startAt'] as int,
      row['endAt'] as int,
      listing,
      seconds,
      false,
    );
    op._requireOpenWindow();
    return op;
  }

  factory QoderClaimOperation.resume(
    Map<String, Object?> record,
    QoderIdentity identity,
  ) {
    if (!identity._valid || identity.region != 'international')
      throw const QoderFailure('IdentityMismatch');
    for (final entry in {
      'providerId': identity.providerId,
      'uid': identity.uid,
      'generation': identity.generation,
      'region': identity.region,
    }.entries) {
      if (record[entry.key] != entry.value)
        throw const QoderFailure('IdentityMismatch');
    }
    final id = record['campaignId'];
    final key = record['campaignKey'];
    final start = record['startAt'];
    final end = record['endAt'];
    if (id is! String ||
        !_safeId(id) ||
        key is! String ||
        key.trim().isEmpty ||
        start is! int ||
        end is! int ||
        start < 0 ||
        start >= end) {
      throw const QoderFailure('InvalidRecord');
    }
    return QoderClaimOperation._(
      identity,
      id,
      key,
      start,
      end,
      null,
      null,
      true,
    );
  }

  /// Non-secret persisted binding. This is never an authentication proof.
  Map<String, Object?> get intent => Map.unmodifiable({
    'providerId': _identity.providerId,
    'uid': _identity.uid,
    'generation': _identity.generation,
    'region': _identity.region,
    'campaignId': _campaignId,
    'campaignKey': _campaignKey,
    'startAt': _start,
    'endAt': _end,
  });

  Future<QoderOutcome> execute({
    required QoderIdentity identity,
    required Future<bool> Function(Map<String, Object?>) persistIntent,
    required Future<QoderReply> Function(QoderRequest) exchange,
  }) async {
    if (!_identity._matches(identity))
      throw const QoderFailure('IdentityMismatch');
    if (_busy) throw const QoderFailure('Busy');
    _busy = true;
    try {
      final recovery = _attempted;
      if (!recovery) {
        _requireOpenWindow();
        // Claim the single local attempt before the first await. Every uncertain
        // persistence/send result leaves this object in GET-only recovery.
        _attempted = true;
        bool saved;
        try {
          saved = await persistIntent(intent);
        } catch (_) {
          throw const QoderFailure('PersistenceUnavailable');
        }
        if (!saved) return QoderOutcome.unknown;
        _requireOpenWindow();
      }
      final path = '$_campaigns/$_campaignId/${recovery ? 'reward' : 'claim'}';
      final request = QoderRequest._(
        recovery ? 'GET' : 'POST',
        Uri.parse('$_origin$path'),
        recovery ? null : '{}',
      );
      try {
        final response = await exchange(
          request,
        ).timeout(const Duration(seconds: 30));
        var result = _receipt(response, path);
        if (recovery &&
            (result == QoderOutcome.newlyClaimed ||
                result == QoderOutcome.alreadyClaimed)) {
          result = QoderOutcome.claimedDeltaUnknown;
        }
        return result;
      } catch (_) {
        return QoderOutcome.unknown;
      }
    } finally {
      _busy = false;
    }
  }

  void _requireOpenWindow() {
    final listing = _listing;
    final seconds = _serverTime;
    if (listing == null || seconds == null)
      throw const QoderFailure('ClockUnverified');
    final elapsed = listing._age.elapsed;
    final total = elapsed + listing.requestElapsed;
    final lower = seconds + elapsed.inSeconds;
    final upper =
        seconds +
        1 +
        (total.inMicroseconds / Duration.microsecondsPerSecond).ceil();
    if (total > const Duration(seconds: 30))
      throw const QoderFailure('ClockUnverified');
    if (lower < _start || upper >= _end)
      throw const QoderFailure('CampaignWindowClosed');
  }

  QoderOutcome _receipt(QoderReply response, String path) {
    if (!_identity._matches(response.identity) ||
        !_expectedUri(response.uri, path))
      return QoderOutcome.unknown;
    final status = response.status;
    if (status == 401 || status == 403)
      return QoderOutcome.verificationRequired;
    if (status == 429) return QoderOutcome.rateLimited;
    if (status != 200 && status != 409) return QoderOutcome.unknown;
    final fallback = status == 409
        ? QoderOutcome.conflict
        : QoderOutcome.unknown;
    final root = response._json;
    if (root == null || !_consistentIdentity(root, _identity.uid))
      return fallback;
    final body = _envelope(root, 'status');
    if (body == null ||
        body['status'] != 'CLAIMED' ||
        body['campaignId'] != _campaignId ||
        body['campaignKey'] != _campaignKey ||
        body['grantId'] is! String ||
        (body['grantId'] as String).trim().isEmpty)
      return fallback;
    final claimed = _rfc3339(body['claimedAt']);
    if (claimed == null || claimed < _start || claimed >= _end) return fallback;
    if (body['replayed'] == true) return QoderOutcome.alreadyClaimed;
    if (body['replayed'] == false && status == 200)
      return QoderOutcome.newlyClaimed;
    if (!body.containsKey('replayed') && status == 200)
      return QoderOutcome.claimedDeltaUnknown;
    return fallback;
  }
}

bool _safeId(String value) => RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(value);
bool _expectedUri(Uri uri, String path) =>
    uri.scheme == 'https' &&
    uri.origin == _origin &&
    uri.userInfo.isEmpty &&
    uri.fragment.isEmpty &&
    uri.path + (uri.hasQuery ? '?${uri.query}' : '') == path;

int _serverDate(QoderReply response) {
  final headers = <String, List<String>>{};
  for (final entry in response.headers.entries) {
    headers.putIfAbsent(entry.key.toLowerCase(), () => []).addAll(entry.value);
  }
  final dates = headers['date'] ?? [];
  final ages = headers['age'] ?? [];
  if (dates.length != 1 ||
      ages.length > 1 ||
      headers.containsKey('via') ||
      (ages.isNotEmpty &&
          (!RegExp(r'^\d+$').hasMatch(ages.single) ||
              int.tryParse(ages.single) != 0)) ||
      response.requestElapsed.isNegative ||
      response.requestElapsed > const Duration(seconds: 30)) {
    throw const QoderFailure('ClockUnverified');
  }
  try {
    final date = dates.single;
    final parsed = HttpDate.parse(date);
    final seconds = parsed.millisecondsSinceEpoch ~/ 1000;
    if (date.length != 29 || HttpDate.format(parsed) != date || seconds < 0)
      throw const FormatException();
    return seconds;
  } catch (_) {
    throw const QoderFailure('ClockUnverified');
  }
}

bool _nonError(Object? value) =>
    value is Map &&
    (!value.containsKey('success') || value['success'] == true) &&
    (!value.containsKey('code') ||
        (value['code'] is int && [0, 200].contains(value['code']))) &&
    (!value.containsKey('errorCode') ||
        value['errorCode'] == null ||
        value['errorCode'] == '' ||
        (value['errorCode'] is int && value['errorCode'] == 0)) &&
    (!value.containsKey('error') || value['error'] == null);

Map? _envelope(Map root, String discriminator) {
  if (!_nonError(root) ||
      (root.containsKey('data') && !_nonError(root['data'])))
    return null;
  final data = root['data'];
  if (root.containsKey(discriminator)) {
    if (data is Map && data.containsKey(discriminator)) return null;
    return root;
  }
  return data is Map ? data : root;
}

bool _consistentIdentity(Map root, String uid) => [
  root,
  if (root['data'] is Map) root['data'] as Map,
].every((body) => !body.containsKey('uid') || body['uid'] == uid);

int? _rfc3339(Object? value) {
  if (value is! String) return null;
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?([Zz]|[+-]\d{2}:\d{2})$',
  ).firstMatch(value);
  if (match == null) return null;
  final values = [for (var i = 1; i <= 6; i++) int.parse(match[i]!)];
  final date = DateTime.utc(
    values[0],
    values[1],
    values[2],
    values[3],
    values[4],
    values[5],
  );
  if (date.year != values[0] ||
      date.month != values[1] ||
      date.day != values[2] ||
      values[3] > 23 ||
      values[4] > 59 ||
      values[5] > 59)
    return null;
  final zone = match[7]!;
  var offset = 0;
  if (zone != 'Z' && zone != 'z') {
    final hour = int.parse(zone.substring(1, 3));
    final minute = int.parse(zone.substring(4, 6));
    if (hour > 23 || minute > 59) return null;
    offset = (hour * 60 + minute) * 60 * (zone[0] == '+' ? 1 : -1);
  }
  return date.millisecondsSinceEpoch ~/ 1000 - offset;
}

// jsonDecode keeps only the last duplicate key. Scan object key tokens first,
// including nested objects and escaped aliases; the standard parser still owns
// full JSON syntax validation. Iterative stack with a bounded nesting depth.
void _rejectDuplicateKeys(String text) {
  final stack = <Set<String>?>[];
  var offset = 0;
  while (offset < text.length) {
    final char = text[offset];
    if (char == '"') {
      final start = offset++;
      var closed = false;
      while (offset < text.length) {
        final unit = text[offset++];
        if (unit == r'\') {
          offset++;
        } else if (unit == '"') {
          closed = true;
          break;
        }
      }
      if (!closed) throw const FormatException();
      var next = offset;
      while (next < text.length && ' \t\r\n'.contains(text[next])) {
        next++;
      }
      if (next < text.length && text[next] == ':') {
        final key = jsonDecode(text.substring(start, offset)) as String;
        if (stack.isEmpty || stack.last == null || !stack.last!.add(key)) {
          throw const FormatException();
        }
      }
      continue;
    }
    if (char == '{' || char == '[') {
      if (stack.length >= 128) throw const FormatException();
      stack.add(char == '{' ? <String>{} : null);
    } else if (char == '}' || char == ']') {
      if (stack.isEmpty) throw const FormatException();
      stack.removeLast();
    }
    offset++;
  }
  if (stack.isNotEmpty) throw const FormatException();
}

/// Shared strict object decoder for responses and non-secret journal entries.
/// Parsing does not establish the source, authentication or ownership of data.
Map<String, dynamic>? decodeQoderObject(String body) {
  if (utf8.encode(body).length > _maxBody) return null;
  try {
    _rejectDuplicateKeys(body);
    final value = jsonDecode(body);
    return value is Map<String, dynamic> ? value : null;
  } on FormatException {
    return null;
  }
}
