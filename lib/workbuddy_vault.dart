import 'dart:convert';
import 'source_digest.dart';
import 'account_registration.dart';

// Saved authorization records require fresh server identity proof on restore.
// The native backend stores plaintext JSON in the private application directory.
abstract interface class WorkBuddyVaultStore {
  Future<Map<String, Object?>?> read(String key);
  Future<bool> compareExchange(
    String key,
    int? expected,
    Map<String, Object?> value,
  );
}

class WorkBuddyVaultCredential {
  final String domain, endpoint, uid, accessToken;
  final String? refreshToken;
  final DateTime? expiresAt, refreshExpiresAt;
  final bool accessRejected, refusalRecoveryAttempted;
  WorkBuddyVaultCredential({
    required this.domain,
    required this.endpoint,
    required this.uid,
    required this.accessToken,
    this.refreshToken,
    this.refreshExpiresAt,
    required this.expiresAt,
    this.accessRejected = false,
    this.refusalRecoveryAttempted = false,
  });
  Map<String, Object?> _encode() => {
    'domain': domain,
    'endpoint': endpoint,
    'uid': uid,
    'accessToken': accessToken,
    if (refreshToken != null) 'refreshToken': refreshToken,
    if (expiresAt != null) 'expiresAt': expiresAt!.millisecondsSinceEpoch,
    if (refreshExpiresAt != null)
      'refreshExpiresAt': refreshExpiresAt!.millisecondsSinceEpoch,
    if (accessRejected) 'accessRejected': true,
    if (refusalRecoveryAttempted) 'refusalRecoveryAttempted': true,
  };
  static WorkBuddyVaultCredential decode(Map<String, Object?> m) {
    String field(String name, int max) {
      final v = m[name];
      if (v is! String ||
          v.isEmpty ||
          v.length > max ||
          RegExp(r'[^\x21-\x7e]').hasMatch(v))
        throw const FormatException('Invalid vault record');
      return v;
    }

    final domain = field('domain', 128), endpoint = field('endpoint', 128);
    if (!['www.workbuddy.cn', 'www.codebuddy.cn'].contains(domain) ||
        !['www.workbuddy.cn', 'www.codebuddy.cn'].contains(endpoint))
      throw const FormatException('Invalid vault binding');
    final expiry = m['expiresAt'];
    if (m.containsKey('expiresAt') &&
        (expiry is! int || expiry <= 0 || expiry > 8640000000000000))
      throw const FormatException('Invalid expiry');
    final refreshExpiry = m['refreshExpiresAt'];
    if (m.containsKey('refreshExpiresAt') &&
        (refreshExpiry is! int ||
            refreshExpiry <= 0 ||
            refreshExpiry > 8640000000000000))
      throw const FormatException('Invalid refresh expiry');
    for (final name in ['accessRejected', 'refusalRecoveryAttempted']) {
      if (m.containsKey(name) && m[name] is! bool)
        throw const FormatException('Invalid authorization status');
    }
    return WorkBuddyVaultCredential(
      domain: domain,
      endpoint: endpoint,
      uid: field('uid', 512),
      accessToken: field('accessToken', 16384),
      refreshToken: m.containsKey('refreshToken')
          ? field('refreshToken', 16384)
          : null,
      expiresAt: expiry == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expiry as int, isUtc: true),
      refreshExpiresAt: refreshExpiry == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              refreshExpiry as int,
              isUtc: true,
            ),
      accessRejected: m['accessRejected'] == true,
      refusalRecoveryAttempted: m['refusalRecoveryAttempted'] == true,
    );
  }

  bool hasExpired(DateTime at) => expiresAt != null && !at.isBefore(expiresAt!);
  bool isUsable(DateTime at) => !accessRejected && !hasExpired(at);
  WorkBuddyVaultCredential withStatus({
    required bool accessRejected,
    required bool refusalRecoveryAttempted,
  }) => WorkBuddyVaultCredential(
    domain: domain,
    endpoint: endpoint,
    uid: uid,
    accessToken: accessToken,
    refreshToken: refreshToken,
    expiresAt: expiresAt,
    refreshExpiresAt: refreshExpiresAt,
    accessRejected: accessRejected,
    refusalRecoveryAttempted: refusalRecoveryAttempted,
  );
  bool needsRenewal(DateTime at) =>
      refreshToken != null &&
      (refreshExpiresAt == null || at.isBefore(refreshExpiresAt!)) &&
      (!accessRejected || !refusalRecoveryAttempted) &&
      (accessRejected ||
          expiresAt != null &&
              !at.add(const Duration(minutes: 1)).isBefore(expiresAt!));
  @override
  String toString() => 'WorkBuddyVaultCredential(redacted)';
}

class WorkBuddyVaultLease {
  final WorkBuddyVaultCredential credential;
  final String registrationId;
  final bool Function() _current;
  final Future<bool> Function() _check;
  WorkBuddyVaultLease._(
    this.credential,
    this.registrationId,
    this._current,
    this._check,
  );
  Future<bool> checkCurrent() => _check();
  bool get current => _current();
  bool get automaticEnabled => false;
  @override
  String toString() => 'WorkBuddyVaultLease(redacted)';
}

class WorkBuddyRotationTicket {
  final String _key;
  final int _revision;
  final Object _owner;
  WorkBuddyRotationTicket._(this._key, this._revision, this._owner);
}

class WorkBuddyVault {
  final WorkBuddyVaultStore store;
  final DateTime Function() now;
  bool _closed = false;
  final _epochs = <String, int>{};
  final _blocked = <String>{};
  final Object _owner = Object();
  WorkBuddyVault(this.store, {DateTime Function()? now})
    : now = now ?? DateTime.now;
  void _key(String key) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key))
      throw const FormatException('Invalid vault key');
  }

  int _retire(String key) {
    _key(key);
    return _epochs[key] = (_epochs[key] ?? 0) + 1;
  }

  bool _current(String key, int epoch) =>
      !_closed && _epochs[key] == epoch && !_blocked.contains(key);
  Map<String, Object?> _record(
    int revision,
    String state, [
    WorkBuddyVaultCredential? c,
    String? registrationId,
  ]) => {
    'schema': 1,
    'revision': revision,
    'state': state,
    if (c != null) ...c._encode(),
    if (registrationId != null) 'registrationId': registrationId,
  };
  void _validate(Map<String, Object?> row) {
    if (row['schema'] != 1 ||
        row['revision'] is! int ||
        (row['revision'] as int) <= 0 ||
        !['active', 'rotationPending', 'revoked'].contains(row['state']))
      throw const FormatException('Invalid vault state');
    final allowed = {
      'schema',
      'revision',
      'state',
      'domain',
      'endpoint',
      'uid',
      'accessToken',
      'refreshToken',
      'expiresAt',
      'refreshExpiresAt',
      'accessRejected',
      'refusalRecoveryAttempted',
      'registrationId',
    };
    if (row['registrationId'] != null &&
        (row['registrationId'] is! String ||
            !RegExp(
              r'^[a-f0-9]{32}$',
            ).hasMatch(row['registrationId'] as String)))
      throw const FormatException('Invalid registration');
    if (row.keys.any((k) => !allowed.contains(k)))
      throw const FormatException('Unknown vault field');
    if (row['state'] == 'revoked') {
      if (row.keys.any((k) => !{'schema', 'revision', 'state'}.contains(k)))
        throw const FormatException('Invalid tombstone');
    } else {
      WorkBuddyVaultCredential.decode(row);
    }
  }

  static String accountKey(String domain, String uid) => sourceSha256(
    utf8.encode(jsonEncode(['workbuddy-v1', domain, uid])),
  ).map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  Future<bool> save(
    String key,
    WorkBuddyVaultCredential credential, {
    bool Function()? admission,
    bool replaceVerified = false,
  }) async {
    final epoch = _retire(key);
    bool admitted() {
      try {
        return _current(key, epoch) && (admission?.call() ?? true);
      } catch (_) {
        return false;
      }
    }

    if (!admitted()) return false;
    WorkBuddyVaultCredential.decode(credential._encode());
    // Ordinary saves never overwrite. Fresh verified reauthorization may replace
    // the same active identity; unresolved rotation and revocation remain closed.
    final previous = await store.read(key);
    if (!admitted()) return false;
    int? expectedRevision;
    if (previous != null) {
      _validate(previous);
      if (!replaceVerified ||
          previous['state'] != 'active' ||
          previous['domain'] != credential.domain ||
          previous['endpoint'] != credential.endpoint ||
          previous['uid'] != credential.uid)
        return false;
      expectedRevision = previous['revision'] as int;
    }
    final desired = _record(
      (expectedRevision ?? 0) + 1,
      'active',
      credential,
      previous?['registrationId'] as String? ?? newAccountRegistrationId(),
    );
    bool saved;
    try {
      saved = await store.compareExchange(key, expectedRevision, desired);
    } catch (_) {
      _retire(key);
      _blocked.add(key);
      // Storage may commit and then fail readback. Clean only our exact record;
      // an unavailable store is explicitly unresolved, never assumed rolled back.
      try {
        final row = await store.read(key), expected = desired;
        if (row != null &&
            row.length == expected.length &&
            expected.entries.every((e) => row[e.key] == e.value))
          await revoke(key);
      } catch (_) {
        throw StateError('Credential save cleanup unresolved');
      }
      throw StateError('Credential save failed');
    }
    if (saved && !admitted()) {
      await revoke(key);
      return false;
    }
    return saved && admitted();
  }

  Future<WorkBuddyVaultLease?> restore(
    String key, {
    required Future<bool> Function(WorkBuddyVaultCredential, bool Function())
    verify,
    Future<WorkBuddyVaultCredential?> Function(
      WorkBuddyVaultCredential,
      bool Function(),
    )?
    renew,
  }) async {
    var epoch = _retire(key);
    if (!_current(key, epoch)) return null;
    try {
      var row = await store.read(key);
      if (row == null) return null;
      _validate(row);
      if (row['state'] != 'active') return null;
      if (row['registrationId'] == null) {
        final migrated = _record(
          (row['revision'] as int) + 1,
          'active',
          WorkBuddyVaultCredential.decode(row),
          newAccountRegistrationId(),
        );
        if (!await store.compareExchange(
              key,
              row['revision'] as int,
              migrated,
            ) ||
            !_current(key, epoch))
          return null;
        row = migrated;
      }
      var credential = WorkBuddyVaultCredential.decode(row);
      if (renew != null && credential.needsRenewal(now())) {
        final original = credential.accessRejected
            ? credential.withStatus(
                accessRejected: true,
                refusalRecoveryAttempted: true,
              )
            : credential;
        final ticket = await beginRotation(key);
        if (ticket == null) return null;
        epoch = _epochs[key]!;
        bool renewing() => _current(key, epoch);
        if (!renewing()) return null;
        // The durable pending record is in place before the single refresh POST.
        var next = await renew(original, renewing);
        if (next != null && original.accessRejected)
          next = next.withStatus(
            accessRejected: false,
            refusalRecoveryAttempted: true,
          );
        if (!renewing()) return null;
        if (next == null) {
          // A definite negative response spent no replacement: keep the prior
          // grant, including a token still usable until its genuine expiry.
          if (!await store.compareExchange(
            key,
            ticket._revision,
            _record(
              ticket._revision + 1,
              'active',
              original,
              row['registrationId'] as String,
            ),
          ))
            return null;
        } else if (!await completeRotation(ticket, next)) {
          return null;
        }
        row = await store.read(key);
        if (row == null || row['state'] != 'active' || !renewing()) return null;
        _validate(row);
        credential = WorkBuddyVaultCredential.decode(row);
      }
      bool admitted() => _current(key, epoch) && credential.isUsable(now());
      if (!admitted() || !await verify(credential, admitted) || !admitted())
        return null;
      // Revocation/rotation may have happened during asynchronous verification.
      final after = await store.read(key);
      if (after == null ||
          after['revision'] != row['revision'] ||
          after['state'] != 'active' ||
          !_current(key, epoch) ||
          !credential.isUsable(now()))
        return null;
      final leaseRevision = row['revision'];
      return WorkBuddyVaultLease._(
        credential,
        row['registrationId'] as String,
        admitted,
        () async {
          if (!admitted()) return false;
          try {
            final latest = await store.read(key);
            final valid =
                admitted() &&
                latest != null &&
                latest['revision'] == leaseRevision &&
                latest['state'] == 'active';
            if (!valid) _retire(key);
            return valid;
          } catch (_) {
            _retire(key);
            return false;
          }
        },
      );
    } catch (_) {
      _retire(key);
      return null;
    }
  }

  /// Observe a definite refusal of exactly the dispatched access token. A late
  /// response cannot alter a replacement token or a different local grant.
  Future<void> rejectAccessToken(
    String key, {
    required String expectedToken,
    required String registrationId,
  }) async {
    bool same(Map<String, Object?>? row) =>
        row != null &&
        row['state'] == 'active' &&
        row['accessToken'] == expectedToken &&
        row['registrationId'] == registrationId;
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        final row = await store.read(key);
        if (_closed || _blocked.contains(key) || !same(row)) return;
        _validate(row!);
        if (row['accessRejected'] == true) {
          _retire(key);
          return;
        }
        final credential = WorkBuddyVaultCredential.decode(row).withStatus(
          accessRejected: true,
          refusalRecoveryAttempted: row['refusalRecoveryAttempted'] == true,
        );
        if (await store.compareExchange(
          key,
          row['revision'] as int,
          _record(
            (row['revision'] as int) + 1,
            'active',
            credential,
            registrationId,
          ),
        )) {
          _retire(key);
          return;
        }
      }
      throw StateError('Authorization status save unresolved');
    } catch (_) {
      // A native write may commit before its acknowledgement is lost.
      try {
        final saved = await store.read(key);
        if (same(saved) && saved!['accessRejected'] == true) {
          _retire(key);
          return;
        }
        if (saved != null && !same(saved)) return;
      } catch (_) {}
      _retire(key);
      _blocked.add(key);
      rethrow;
    }
  }

  Future<WorkBuddyRotationTicket?> beginRotation(String key) async {
    final epoch = _retire(key);
    if (!_current(key, epoch)) return null;
    final row = await store.read(key);
    if (row == null) return null;
    _validate(row);
    if (row['state'] != 'active' || !_current(key, epoch)) return null;
    var c = WorkBuddyVaultCredential.decode(row);
    if (c.refreshToken == null) return null;
    if (c.accessRejected)
      c = c.withStatus(accessRejected: true, refusalRecoveryAttempted: true);
    final revision = (row['revision'] as int) + 1;
    // Durable uncertainty marker MUST precede any future refresh transmission.
    if (!await store.compareExchange(
      key,
      row['revision'] as int,
      _record(
        revision,
        'rotationPending',
        c,
        row['registrationId'] as String? ?? newAccountRegistrationId(),
      ),
    ))
      return null;
    if (!_current(key, epoch)) return null;
    return WorkBuddyRotationTicket._(key, revision, _owner);
  }

  Future<bool> completeRotation(
    WorkBuddyRotationTicket ticket,
    WorkBuddyVaultCredential replacement,
  ) async {
    if (_closed ||
        !identical(ticket._owner, _owner) ||
        _blocked.contains(ticket._key))
      return false;
    WorkBuddyVaultCredential.decode(replacement._encode());
    if (!replacement.isUsable(now())) return false;
    final row = await store.read(ticket._key);
    if (row == null) return false;
    _validate(row);
    if (_closed ||
        _blocked.contains(ticket._key) ||
        row['revision'] != ticket._revision ||
        row['state'] != 'rotationPending' ||
        row['domain'] != replacement.domain ||
        row['endpoint'] != replacement.endpoint ||
        row['uid'] != replacement.uid)
      return false;
    return store.compareExchange(
      ticket._key,
      ticket._revision,
      _record(
        ticket._revision + 1,
        'active',
        replacement,
        row['registrationId'] as String,
      ),
    );
  }

  Future<void> revoke(String key) async {
    _retire(key);
    _blocked.add(key); // Failures cannot revive this process's lease.
    // A missing record also gets a tombstone; concurrent save cannot resurrect.
    for (var attempt = 0; attempt < 3; attempt++) {
      final row = await store.read(key);
      if (row != null) _validate(row);
      if (row?['state'] == 'revoked') return;
      final revision = row?['revision'] as int?;
      if (await store.compareExchange(
        key,
        revision,
        _record((revision ?? 0) + 1, 'revoked'),
      ))
        return;
    }
    throw StateError('Local revocation unresolved');
    // Credential-free tombstone persists. Claim intent journal is untouched.
  }

  void close() {
    _closed = true;
    for (final key in _epochs.keys.toList()) {
      _retire(key);
      _blocked.add(key);
    }
  }
}
