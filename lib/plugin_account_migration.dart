import 'dart:convert';

import 'package:crypto/crypto.dart';

class MigratedPluginAccount {
  final String key, provider, scope, oldId;
  final Map<String, dynamic>? auth;
  final Map<String, dynamic> facts;
  MigratedPluginAccount(
    this.key,
    this.provider,
    this.scope,
    this.oldId,
    this.auth,
    this.facts,
  );
}

/// One-time translation of the former LoongPass stores. No network, refresh or
/// claims are allowed here. The frozen originals are retained by the migrator.
List<MigratedPluginAccount> convertPluginAccounts(
  Map<String, dynamic> sources,
) {
  final out = <MigratedPluginAccount>[];
  for (final source in sources.entries) {
    final scope = source.key;
    if (!const {
      'MiniMax-cn',
      'MiniMax-global',
      'Qoder-cn',
      'Qoder-global',
      'TRAE-cn',
      'WorkBuddy',
      'ZCode',
      'RewardChannels',
    }.contains(scope))
      continue;
    final document = Map<String, dynamic>.from(source.value as Map);
    final rows = scope == 'WorkBuddy'
        ? document
        : (document['accounts'] as Map? ?? {});
    for (final entry in rows.entries) {
      final oldId = entry.key as String;
      final row = Map<String, dynamic>.from(entry.value as Map);
      if (scope == 'WorkBuddy' && row['state'] == 'revoked') continue;
      if (scope == 'RewardChannels' && row['provider'] != 'loomy') continue;
      late final String provider, uid, realm;
      late final Map<String, dynamic> auth;
      if (scope.startsWith('MiniMax-')) {
        realm = scope.substring('MiniMax-'.length);
        provider = realm == 'cn' ? 'minimax-code' : 'minimax-code-global';
        uid = _text(row['uid']);
        auth = _oauth(
          uid,
          row['accessToken'],
          row['refreshToken'],
          row['expiresAtMs'],
        )..addAll({'realUserID': uid, 'name': row['label'] ?? uid});
      } else if (scope.startsWith('Qoder-')) {
        realm = scope.substring('Qoder-'.length);
        provider = realm == 'cn' ? 'qoder-cn' : 'qoder';
        uid = _text(oldId);
        auth = _oauth(uid, row['token'], row['refreshToken'], row['expiresAt'])
          ..addAll({
            'deviceChat': true,
            'deviceToken': row['token'],
            'deviceRefresh': row['refreshToken'] ?? '',
            'machineId': _text(row['machineId']),
          });
      } else if (scope == 'TRAE-cn') {
        realm = 'cn';
        provider = 'trae-cn';
        uid = _text(row['uid']);
        final device = row['device'] as Map;
        auth =
            _oauth(
              uid,
              row['token'],
              row['owner'] == 'loongpass' ? row['refreshToken'] : '',
              row['expiresAt'],
            )..addAll({
              'clientId': 'ono9krqynydwx5',
              'deviceId': _text(device['DeviceID']),
              'machineId': _text(device['MachineID']),
              if (device['DevicePublicKey'] != null)
                'devicePublicKey': device['DevicePublicKey'],
              if (row['privateKeyPEM'] != null)
                'devicePrivateKey': row['privateKeyPEM'],
            });
      } else if (scope == 'WorkBuddy') {
        realm = _text(row['domain']);
        provider = 'workbuddy';
        uid = _text(row['uid']);
        auth =
            _oauth(
              uid,
              row['accessToken'],
              row['refreshToken'],
              row['expiresAt'],
            )..addAll({
              'domain': realm,
              if (row['refreshExpiresAt'] != null)
                'refreshExpiresAt': row['refreshExpiresAt'],
            });
      } else if (scope == 'ZCode') {
        realm = _text(row['family']);
        if (!{'bigmodel', 'zai'}.contains(realm))
          throw const FormatException('Unknown ZCode region');
        provider = 'zcode';
        uid = _text(row['uid']);
        final jwt = _text(row['token']);
        auth = _oauth(
          uid,
          jwt,
          jsonEncode({
            'site': realm,
            'jwt': jwt,
            'device': _text(row['context']['deviceMid']),
            'key': '',
          }),
          _jwtExpiry(jwt),
        );
        // Region is part of this identity; equal vendor IDs in different sites
        // cannot coalesce in the native host's display-name deduplication.
        auth['accountId'] = '$realm:$uid';
      } else {
        realm = 'cn';
        provider = 'loomy';
        uid = _text(row['identity']);
        final credentials = row['credentials'] as Map;
        if (_text(credentials['userid']) != uid)
          throw const FormatException('Loomy identity mismatch');
        auth = _oauth(uid, credentials['access_token'], '', 0)
          ..['userId'] = uid;
      }
      final unknown =
          row['refreshPending'] == true || row['state'] == 'rotationPending';
      final invalid = row['authorizationInvalid'] == true;
      final key =
          '$provider#lp${sha256.convert(utf8.encode('$realm\u0000$uid')).toString().substring(0, 32)}';
      if (out.any((a) => a.key == key))
        throw const FormatException('Duplicate source identity');
      final legacy = Map<String, dynamic>.from(_withoutCredentials(row) as Map);
      if (scope.startsWith('Qoder-')) {
        legacy['claims'] = {
          for (final c in (document['claims'] as Map? ?? {}).entries)
            if ((jsonDecode(c.key as String) as List).first == uid)
              c.key: c.value,
        };
      }
      if (scope == 'RewardChannels') {
        legacy['journals'] = (document['journals'] as Map?)?[oldId] ?? {};
      }
      if (scope == 'WorkBuddy') {
        legacy['journal'] = (sources['WorkBuddyClaims'] as Map?)?[oldId];
      }
      final facts = <String, dynamic>{
        'provider': provider,
        'uid': uid,
        'realm': realm,
        'label': row['label'] ?? uid,
        'automatic': row['automatic'] ?? true,
        'registrationId': row['registrationId'] ?? key,
        'sourceScope': scope,
        'sourceId': oldId,
        'legacy': legacy,
        if (unknown || invalid)
          'quarantine': unknown ? 'refresh_unknown' : 'authorization_required',
      };
      out.add(
        MigratedPluginAccount(
          key,
          provider,
          scope,
          oldId,
          unknown || invalid ? null : auth,
          facts,
        ),
      );
    }
  }
  return out;
}

String _text(Object? value) {
  if (value is! String || value.trim().isEmpty || value.contains('\u0000')) {
    throw const FormatException('Invalid legacy credential identity');
  }
  return value;
}

Map<String, dynamic> _oauth(
  String uid,
  Object? access,
  Object? refresh,
  Object? expires,
) => {
  'type': 'oauth',
  'uid': uid,
  'accountId': uid,
  'access': _text(access),
  'refresh': refresh == null || refresh == '' ? '' : _text(refresh),
  'expires': expires == null
      ? 0
      : expires is int && expires >= 0
      ? expires
      : throw const FormatException('Invalid credential expiry'),
};

int _jwtExpiry(String token) {
  try {
    final fields = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1]))),
    );
    final seconds = fields['exp'];
    return seconds is int && seconds > 0 && seconds < 8640000000000
        ? seconds * 1000
        : 0;
  } catch (_) {
    return 0; // A historical opaque grant has no proven expiry.
  }
}

Object? _withoutCredentials(Object? value) {
  if (value is Map)
    return {
      for (final entry in value.entries)
        if (!const {
          'accessToken',
          'refreshToken',
          'token',
          'access',
          'refresh',
          'credentials',
          'privateKeyPEM',
          'devicePrivateKey',
        }.contains(entry.key))
          entry.key: _withoutCredentials(entry.value),
    };
  if (value is List) return value.map(_withoutCredentials).toList();
  return value;
}
