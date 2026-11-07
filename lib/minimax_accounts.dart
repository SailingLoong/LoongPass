import 'claim_receipt.dart';
// Regional MiniMax account owner. Credentials, identity and claim journal are
// atomically stored together in one private native-owned document.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'minimax_http.dart';
import 'minimax_oauth.dart';
import 'minimax_credits.dart';
import 'credit_summary.dart';
import 'source_digest.dart';
import 'account_document_store.dart';

class MiniMaxAccountError implements Exception {
  final String code;
  const MiniMaxAccountError(this.code);
  @override
  String toString() => code;
}

enum _Region { cn, global }

class MiniMaxCredential {
  final String region, fingerprint, _accessToken;
  final String? _refreshToken;
  final int generation, expiresAtMs;
  MiniMaxCredential._(
    this.region,
    this.fingerprint,
    this._accessToken,
    this.generation,
    this.expiresAtMs, [
    this._refreshToken,
  ]);
  static MiniMaxCredential parse(
    Uint8List bytes, {
    required String sourcePath,
    required String region,
    required int nowMs,
  }) {
    if (!['cn', 'global'].contains(region) || !_safeInt(nowMs))
      throw const MiniMaxAccountError('InvalidImport');
    return _parseCandidate(
      bytes,
      sourcePath,
      region == 'cn' ? _Region.cn : _Region.global,
      nowMs,
    );
  }

  factory MiniMaxCredential.authorization(
    MiniMaxOAuthToken token,
    String region,
  ) {
    if (!['cn', 'global'].contains(region))
      throw const MiniMaxAccountError('InvalidRegion');
    final fingerprint = sourceSha256(
      utf8.encode('$region\u0000${token.accessToken}'),
    ).map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return MiniMaxCredential._(
      region,
      fingerprint,
      token.accessToken,
      0,
      token.expiresAtMs,
      token.refreshToken,
    );
  }
  @override
  String toString() => 'MiniMaxCredential(redacted)';
}

class MiniMaxVerifiedImport {
  final MiniMaxAccounts _owner;
  final Future<MiniMaxCredential> Function() _read;
  final MiniMaxCredential _credential;
  final String uid, label, id;
  final int? _previousGeneration;
  bool _consumed = false;
  MiniMaxVerifiedImport._(
    this._owner,
    this._read,
    this._credential,
    this.uid,
    this.label,
    this.id,
    this._previousGeneration,
  );
  @override
  String toString() => 'MiniMaxVerifiedImport(redacted)';
}

class MiniMaxAccount {
  final String id, status, uid, region, label;
  final String? registrationId;
  final bool automatic;
  final num? points;
  final ClaimReceipt? latestClaim;
  final int expiresAtMs;
  MiniMaxAccount._(Map<String, dynamic> a)
    : id = a['id'],
      registrationId = a['registrationId'],
      status = a['status'],
      uid = a['uid'],
      region = a['region'],
      label = a['label'],
      automatic = a['automatic'],
      points = (a['operation'] as Map?)?['points'],
      latestClaim = _latest(a),
      expiresAtMs = a['expiresAtMs'],
      _rewardExpiresAtMs = (a['operation'] as Map?)?['expiresAtMs'];
  static ClaimReceipt? _latest(Map a) {
    final op = (a['operation'] as Map?)?['state'] == 'claimed'
        ? a['operation']
        : a['previousSuccessfulOperation'];
    if (op is! Map || op['state'] != 'claimed') return null;
    return ClaimReceipt(
      amount: op['points'],
      day: op['day'],
      confirmedAt: op['confirmedAtMs'] is int
          ? DateTime.fromMillisecondsSinceEpoch(op['confirmedAtMs'])
          : null,
    );
  }

  int? get rewardExpiresAtMs => _rewardExpiresAtMs;
  final int? _rewardExpiresAtMs;
  Map<String, Object?> toJson() => {
    'id': id,
    'uid': uid,
    'label': label,
    'region': region,
    'status': status,
    'automatic': automatic,
    'points': points,
    'expiresAtMs': expiresAtMs,
  };
  @override
  String toString() => 'MiniMaxAccount(redacted)';
}

/// The platform file owner provides atomic credential + identity publication.
class MiniMaxAccountStore {
  final AccountDocumentStore documents;
  MiniMaxAccountStore(this.documents);
  String get identity => documents.identity;
  Future<T> _access<T>(
    Future<T> Function(Map<String, dynamic>) action, {
    bool write = false,
  }) async {
    try {
      final snapshot = await documents.read();
      final doc = snapshot.data.isEmpty
          ? <String, dynamic>{'version': 1, 'accounts': <String, dynamic>{}}
          : snapshot.data;
      _validateMetadata(doc);
      final result = await action(doc['accounts'] as Map<String, dynamic>);
      if (write) {
        _validateMetadata(doc);
        await documents.write(snapshot.revision, doc);
      }
      return result;
    } on MiniMaxAccountError {
      rethrow;
    } catch (_) {
      throw const MiniMaxAccountError('StorageUnavailable');
    }
  }

  static void _validateMetadata(Map<String, dynamic> doc) {
    if (doc['version'] != 1 ||
        doc['accounts'] is! Map<String, dynamic> ||
        doc.keys.any((k) => !['version', 'accounts'].contains(k)))
      throw const MiniMaxAccountError('StorageUnavailable');
    const keys = {
      'id',
      'uid',
      'label',
      'region',
      'generation',
      'expiresAtMs',
      'accessToken',
      'refreshToken',
      'identityVerified',
      'authorizationInvalid',
      'automatic',
      'policyRevision',
      'status',
      'operation',
      'previousSuccessfulOperation',
      'sourceGeneration',
      'sourceFingerprint',
      'registrationId',
    };
    for (final e in (doc['accounts'] as Map<String, dynamic>).entries) {
      final a = e.value;
      if (a is! Map<String, dynamic> ||
          a.keys.any((k) => !keys.contains(k)) ||
          a['id'] != e.key ||
          !['cn', 'global'].contains(a['region']) ||
          a['uid'] is! String ||
          a['label'] is! String ||
          a['registrationId'] != null &&
              !_validText(a['registrationId'], 128) ||
          a['generation'] is! int ||
          a['expiresAtMs'] is! int ||
          !_validText(a['accessToken'], 16384) ||
          a['refreshToken'] != null && !_validText(a['refreshToken'], 16384) ||
          a['identityVerified'] is! bool ||
          a['authorizationInvalid'] is! bool ||
          a['automatic'] is! bool ||
          a['policyRevision'] is! int ||
          ![
            'unavailable',
            'claimable',
            'claimed',
            'alreadyClaimed',
            'unknown',
            'needsLogin',
          ].contains(a['status']))
        throw const MiniMaxAccountError('StorageUnavailable');
      for (final op in [a['operation'], a['previousSuccessfulOperation']]) {
        if (op != null &&
            (op is! Map ||
                op.keys.any(
                  (k) => ![
                    'id',
                    'day',
                    'state',
                    'points',
                    'claimId',
                    'confirmedAtMs',
                    'expiresAtMs',
                  ].contains(k),
                ) ||
                op['id'] is! String ||
                op['day'] is! String ||
                ![
                  'pending',
                  'unknown',
                  'claimed',
                  'alreadyClaimed',
                ].contains(op['state'])))
          throw const MiniMaxAccountError('StorageUnavailable');
      }
    }
  }
}

class MiniMaxAccounts {
  final MiniMaxAccountStore store;
  final MiniMaxHttp http;
  final int Function() nowMs;
  final FutureOr<void> Function()? onAutomaticFinished;
  static final _busy = <String>{};
  bool _closed = false, _ticking = false;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  MiniMaxOAuth? _login;
  Timer? _loginTimer;
  bool _savingLogin = false;
  String? loginMessage;
  bool get loginPending => _login != null;
  String? get loginCode => _login?.userCode;
  Future<Uri> beginAuthorization(String region) async {
    _alive();
    if (_login != null) throw const MiniMaxAccountError('Busy');
    final login = MiniMaxOAuth(region: region, http: http, nowMs: nowMs);
    _login = login;
    try {
      final uri = await login.begin();
      _alive();
      loginMessage = '请在官网完成授权，正在等待结果。';
      return uri;
    } catch (_) {
      if (identical(_login, login)) _login = null;
      login.cancel();
      rethrow;
    }
  }

  void pollAuthorization() {
    _alive();
    _loginTimer?.cancel();
    _loginTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_finishAuthorization()),
    );
  }

  Future<void> _finishAuthorization() async {
    final login = _login;
    if (_closed || login == null || _savingLogin) return;
    _savingLogin = true;
    try {
      final token = await login.poll();
      if (token == null || _closed || !identical(_login, login)) return;
      final credential = MiniMaxCredential.authorization(token, login.region);
      final verified = await verifySource(() async {
        if (_closed || !identical(_login, login))
          throw const MiniMaxAccountError('Closed');
        return credential;
      }, confirmed: true);
      await save(verified, confirmed: true, automatic: true);
      startAutomatic();
      _loginTimer?.cancel();
      _loginTimer = null;
      login.cancel();
      _login = null;
      loginMessage = '账号已验证并保存，自动签到已开启。';
    } on MiniMaxOAuthFailure catch (e) {
      if (!login.active) {
        _loginTimer?.cancel();
        _loginTimer = null;
        _login = null;
        loginMessage = '授权已结束（${e.code}）。';
      }
    } catch (_) {
      loginMessage = '授权结果保留中，正在重试身份读取或本机保存。';
    } finally {
      _savingLogin = false;
      try {
        if (!_closed) {
          _changes.add(null);
          await onAutomaticFinished?.call();
        }
      } catch (_) {
        // A display refresh cannot undo the saved authorization.
      }
    }
  }

  void cancelAuthorization() {
    _loginTimer?.cancel();
    _loginTimer = null;
    _login?.cancel();
    _login = null;
  }

  Timer? _startupTimer, _timer;
  MiniMaxAccounts({
    required this.store,
    this.onAutomaticFinished,
    MiniMaxHttp? http,
    int Function()? nowMs,
  }) : http = http ?? MiniMaxHttp(),
       nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);
  void _alive() {
    if (_closed) throw const MiniMaxAccountError('Closed');
  }

  String _ownerKey(String id) => '${store.identity}\u0000$id';
  String _day() => DateTime.fromMillisecondsSinceEpoch(
    nowMs(),
    isUtc: true,
  ).toIso8601String().substring(0, 10);
  Future<MiniMaxReply> _send(
    MiniMaxEndpoint endpoint,
    String token,
    String region, [
    String? uid,
    bool Function()? admission,
  ]) async {
    _alive();
    try {
      final r = await http.send(
        endpoint,
        accessToken: token,
        region: region,
        userId: uid,
        isCurrent: () => !_closed && (admission?.call() ?? true),
      );
      _alive();
      return r;
    } on MiniMaxAccountError {
      rethrow;
    } catch (_) {
      _alive();
      throw const MiniMaxAccountError('NetworkUnavailable');
    }
  }

  Future<MiniMaxVerifiedImport> verifySource(
    Future<MiniMaxCredential> Function() read, {
    required bool confirmed,
  }) async {
    if (!confirmed) throw const MiniMaxAccountError('ConfirmationRequired');
    _alive();
    final before = await store._access(
      (a) async => {
        for (final e in a.entries) e.key: (e.value as Map)['generation'],
      },
    );
    final c = await read();
    _alive();
    if (c.expiresAtMs <= nowMs()) throw const MiniMaxAccountError('NeedsLogin');
    final profile = _profile(
      await _send(MiniMaxEndpoint.profile, c._accessToken, c.region),
    );
    final again = await read();
    _alive();
    if (again.fingerprint != c.fingerprint || again.region != c.region)
      throw const MiniMaxAccountError('SourceChanged');
    final key =
        '${c.region}:${sourceSha256(utf8.encode('${c.region}\u0000${profile.$1}')).map((v) => v.toRadixString(16).padLeft(2, '0')).join()}';
    return MiniMaxVerifiedImport._(
      this,
      read,
      c,
      profile.$1,
      profile.$2,
      key,
      before[key] as int?,
    );
  }

  Future<MiniMaxVerifiedImport> verifyFile(
    String path, {
    required String region,
    required bool confirmed,
  }) => verifySource(
    () => readMiniMaxCredentialFile(path, region: region, nowMs: nowMs()),
    confirmed: confirmed,
  );
  Future<MiniMaxAccount> save(
    MiniMaxVerifiedImport value, {
    required bool confirmed,
    bool automatic = false,
  }) async {
    if (!confirmed) throw const MiniMaxAccountError('ConfirmationRequired');
    _alive();
    if (value._owner != this) throw const MiniMaxAccountError('SourceChanged');
    if (value._consumed) throw const MiniMaxAccountError('ImportCompleted');
    if (!_busy.add(_ownerKey(value.id)))
      throw const MiniMaxAccountError('Busy');
    try {
      value._consumed = true;
      final c = await value._read();
      _alive();
      if (c.fingerprint != value._credential.fingerprint ||
          c.region != value._credential.region)
        throw const MiniMaxAccountError('SourceChanged');
      if (c.expiresAtMs <= nowMs())
        throw const MiniMaxAccountError('NeedsLogin');
      final saved = await store._access((accounts) async {
        final old = accounts[value.id] as Map?;
        if (old?['generation'] != value._previousGeneration)
          throw const MiniMaxAccountError('SourceChanged');
        final generation = (old?['generation'] as int? ?? 0) + 1;
        _alive();
        final last = await value._read();
        _alive();
        if (last.fingerprint != c.fingerprint || last.expiresAtMs <= nowMs())
          throw const MiniMaxAccountError('SourceChanged');
        final operation = old?['operation'];
        final account = <String, dynamic>{
          'id': value.id,
          'uid': value.uid,
          'label': value.label,
          'region': c.region,
          'generation': generation,
          'registrationId': old?['registrationId'] ?? _nonce(),
          'expiresAtMs': c.expiresAtMs,
          'accessToken': c._accessToken,
          'refreshToken': c._refreshToken,
          'identityVerified': true,
          'authorizationInvalid': false,
          'automatic': automatic,
          'policyRevision': (old?['policyRevision'] as int? ?? 0) + 1,
          'status': _unresolved(operation) ? 'unknown' : 'unavailable',
          'operation': operation,
          'previousSuccessfulOperation': old?['previousSuccessfulOperation'],
          'sourceGeneration': c.generation,
          'sourceFingerprint': c.fingerprint,
        };
        accounts[value.id] = account;
        return MiniMaxAccount._(account);
      }, write: true);
      _rotations.remove(value.id);
      _verified[value.id] = (await _account(value.id))['generation'];
      _changes.add(null);
      return saved;
    } finally {
      _busy.remove(_ownerKey(value.id));
    }
  }

  final _verified = <String, int>{};
  final _rotations = <String, (Map<String, dynamic>, MiniMaxOAuthToken)>{};
  Future<Map<String, dynamic>> _authorized(String id) async {
    var account = await _account(id);
    if (account['authorizationInvalid'] == true)
      throw const MiniMaxAccountError('NeedsLogin');
    var pending = _rotations[id];
    if (pending != null &&
        account['generation'] == pending.$1['generation'] + 1 &&
        account['accessToken'] == pending.$2.accessToken &&
        account['refreshToken'] == pending.$2.refreshToken) {
      // A write may have committed before its acknowledgement was lost.
      _rotations.remove(id);
      pending = null;
    }
    final refresh = account['refreshToken'];
    if (pending == null &&
        account['expiresAtMs'] <= nowMs() + 60000 &&
        refresh is String) {
      try {
        final next = await MiniMaxOAuth.refresh(
          http: http,
          region: account['region'],
          refreshToken: refresh,
          nowMs: nowMs,
        );
        pending = (account, next);
        _rotations[id] = pending;
      } on MiniMaxOAuthFailure catch (e) {
        if (e.code == 'invalid_grant') {
          await store._access((rows) async {
            final current = _match(rows, id, account);
            current['authorizationInvalid'] = true;
            current['status'] = 'needsLogin';
          }, write: true);
          throw const MiniMaxAccountError('NeedsLogin');
        }
        if (account['expiresAtMs'] <= nowMs())
          throw const MiniMaxAccountError('NetworkUnavailable');
      }
    }
    if (pending != null) {
      final rotation = pending;
      // Rotation is saved before profile lookup. A temporary identity failure
      // or restart therefore cannot replay the old, rotated refresh token.
      account = await store._access((rows) async {
        final current = _match(rows, id, rotation.$1);
        current['accessToken'] = rotation.$2.accessToken;
        current['refreshToken'] = rotation.$2.refreshToken;
        current['expiresAtMs'] = rotation.$2.expiresAtMs;
        current['generation'] = (current['generation'] as int) + 1;
        current['identityVerified'] = false;
        return Map<String, dynamic>.from(current);
      }, write: true);
      _rotations.remove(id);
    }
    if (account['expiresAtMs'] <= nowMs())
      throw const MiniMaxAccountError('NeedsLogin');
    if (_verified[id] != account['generation']) {
      final profile = _profile(
        await _send(
          MiniMaxEndpoint.profile,
          account['accessToken'],
          account['region'],
        ),
      );
      if (profile.$1 != account['uid'])
        throw const MiniMaxAccountError('IdentityMismatch');
      if (account['identityVerified'] != true) {
        await store._access((rows) async {
          _match(rows, id, account)['identityVerified'] = true;
        }, write: true);
        account['identityVerified'] = true;
      }
      _verified[id] = account['generation'];
    }
    return account;
  }

  final _credits = <String, CreditSummary>{};
  CreditSummary? credits(String id) => _credits[id];

  /// The same account lock and refresh/identity owner used by other operations.
  /// Keep the lease until the caller has consumed or cancelled the response.
  Future<T> withInferenceAuthorization<T>(
    String id,
    Future<T> Function(
      String region,
      String token,
      bool Function() isCurrent,
      String registrationId,
    )
    use, {
    String? expectedRegistrationId,
  }) async {
    _alive();
    if (!_busy.add(_ownerKey(id))) throw const MiniMaxAccountError('Busy');
    var active = true;
    try {
      var account = await _authorized(id);
      if (account['registrationId'] == null) {
        account = await store._access((rows) async {
          final current = _match(rows, id, account);
          current['registrationId'] = _nonce();
          return Map<String, dynamic>.from(current);
        }, write: true);
      }
      final registration = account['registrationId'] as String;
      if (expectedRegistrationId != null &&
          expectedRegistrationId != registration)
        throw const MiniMaxAccountError('SourceChanged');
      return await use(
        account['region'],
        account['accessToken'],
        () => active && !_closed && account['expiresAtMs'] > nowMs(),
        registration,
      );
    } finally {
      active = false;
      _busy.remove(_ownerKey(id));
    }
  }

  Future<void> refreshCredits(String id) async {
    _alive();
    if (!_busy.add(_ownerKey(id))) throw const MiniMaxAccountError('Busy');
    _credits.remove(id);
    try {
      final account = await _authorized(id);
      final token = account['accessToken'] as String;
      final pages = <Map<String, dynamic>>[];
      var received = 0;
      for (var page = 1; page <= 500; page++) {
        final response = await http.credits(
          accessToken: token,
          region: account['region'],
          userId: account['uid'],
          pageNumber: page,
          isCurrent: () => !_closed && account['expiresAtMs'] > nowMs(),
        );
        _alive();
        final body = response.body;
        if (response.status != 200 || body == null)
          throw const MiniMaxAccountError('InvalidResponse');
        final pageDetails = parseMiniMaxCreditPage(body);
        received += pageDetails.rows.length;
        pages.add(body);
        if (received >= pageDetails.totalCount) break;
        if (pageDetails.rows.isEmpty)
          throw const MiniMaxAccountError('InvalidResponse');
      }
      await store._access((a) async {
        _match(a, id, account);
        return null;
      });
      _alive();
      _credits[id] = normalizeMiniMaxCredits(
        pages,
        now: DateTime.fromMillisecondsSinceEpoch(nowMs(), isUtc: true),
      );
    } finally {
      _busy.remove(_ownerKey(id));
    }
  }

  Future<List<MiniMaxAccount>> list() async {
    _alive();
    return store._access(
      (a) async => [
        for (final v in a.values) MiniMaxAccount._(v as Map<String, dynamic>),
      ],
    );
  }

  Future<Map<String, dynamic>> _account(String id) => store._access((a) async {
    final value = a[id];
    if (value is! Map<String, dynamic>)
      throw const MiniMaxAccountError('AccountMissing');
    return Map<String, dynamic>.from(value);
  });
  Future<MiniMaxAccount> setAutomatic(String id, bool enabled) async {
    _alive();
    if (!_busy.add(_ownerKey(id))) throw const MiniMaxAccountError('Busy');
    try {
      return await store._access((a) async {
        final row = a[id] as Map<String, dynamic>?;
        if (row == null) throw const MiniMaxAccountError('AccountMissing');
        row['automatic'] = enabled;
        row['policyRevision'] = (row['policyRevision'] as int) + 1;
        return MiniMaxAccount._(row);
      }, write: true);
    } finally {
      _busy.remove(_ownerKey(id));
    }
  }

  Future<MiniMaxAccount> claim(String id) => _claim(id, false);
  Future<MiniMaxAccount> _claim(String id, bool automatic) async {
    _alive();
    if (!_busy.add(_ownerKey(id))) throw const MiniMaxAccountError('Busy');
    try {
      var account = await _account(id);
      _alive();
      if (automatic && account['automatic'] != true)
        return MiniMaxAccount._(account);
      if (_unresolved(account['operation']) ||
          (account['operation'] as Map?)?['day'] == _day())
        return MiniMaxAccount._(account);
      account = await _authorized(id);
      final token = account['accessToken'] as String;
      final statusDay = _day();
      final status = _panel(
        _data(
          await _send(
            MiniMaxEndpoint.status,
            token,
            account['region'],
            account['uid'],
          ),
        ),
        automatic: automatic,
      );
      if ((account['expiresAtMs'] as int) <= nowMs())
        throw const MiniMaxAccountError('NeedsLogin');
      if (statusDay != _day()) throw const MiniMaxAccountError('StatusExpired');
      final opId = _nonce();
      final prepared = await store._access((a) async {
        _alive();
        final current = _match(a, id, account);
        if (automatic &&
            (current['automatic'] != true ||
                current['policyRevision'] != account['policyRevision']))
          throw const MiniMaxAccountError('AutomaticDisabled');
        if (_unresolved(current['operation']) ||
            (current['operation'] as Map?)?['day'] == _day())
          return false;
        current['status'] = status;
        if (status != 'claimable') return false;
        if ((current['operation'] as Map?)?['state'] == 'claimed') {
          current['previousSuccessfulOperation'] = current['operation'];
        }
        current['operation'] = {
          'id': opId,
          'day': _day(),
          'state': 'pending',
          'points': null,
          'claimId': null,
        };
        current['status'] = 'unknown';
        return true;
      }, write: true);
      if (!prepared) return MiniMaxAccount._(await _account(id));
      // Pending marker is durably published before the one POST. Re-check the
      // current identity and opt-in after persistence; never auto-replay POST.
      await store._access((a) async {
        _alive();
        final current = _match(a, id, account);
        if ((current['operation'] as Map?)?['id'] != opId)
          throw const MiniMaxAccountError('SourceChanged');
        if (automatic &&
            (current['automatic'] != true ||
                current['policyRevision'] != account['policyRevision']))
          throw const MiniMaxAccountError('AutomaticDisabled');
        return null;
      });
      if ((account['expiresAtMs'] as int) <= nowMs())
        throw const MiniMaxAccountError('NeedsLogin');
      if (statusDay != _day()) throw const MiniMaxAccountError('StatusExpired');
      (String, num, String, int)? receipt;
      try {
        receipt = _receipt(
          await _send(
            MiniMaxEndpoint.claim,
            token,
            account['region'],
            account['uid'],
            () =>
                (account['expiresAtMs'] as int) > nowMs() &&
                statusDay == _day(),
          ),
        );
      } catch (_) {
        /* Pending remains unknown; no POST retry. */
      }
      _alive();
      return await store._access((a) async {
        _alive();
        final current = _match(a, id, account);
        final op = current['operation'] as Map;
        if (op['id'] != opId) throw const MiniMaxAccountError('SourceChanged');
        op['state'] = receipt?.$1 ?? 'unknown';
        op['points'] = receipt?.$2;
        if (receipt?.$1 == 'claimed') {
          op['confirmedAtMs'] = nowMs();
          current.remove('previousSuccessfulOperation');
        }
        op['claimId'] = receipt?.$3;
        op['expiresAtMs'] = receipt?.$4;
        current['status'] = receipt?.$1 ?? 'unknown';
        return MiniMaxAccount._(current);
      }, write: true);
    } finally {
      _busy.remove(_ownerKey(id));
    }
  }

  Future<void> automaticTick() async {
    _alive();
    if (_ticking) return;
    _ticking = true;
    try {
      for (final a in await list()) {
        if (_closed) break;
        if (a.automatic) {
          try {
            await _claim(a.id, true);
          } on MiniMaxAccountError catch (e) {
            if (e.code == 'NeedsLogin') {
              try {
                await store._access((rows) async {
                  rows[a.id]?['status'] = 'needsLogin';
                }, write: true);
              } catch (_) {}
            }
          }
        }
        try {
          await refreshCredits(a.id);
        } catch (_) {
          // Credits are independent of automatic rewards and their outcome.
        }
      }
    } finally {
      try {
        if (!_closed) {
          _changes.add(null);
          await onAutomaticFinished?.call();
        }
      } catch (_) {
        /* UI refresh must not change the claim outcome. */
      } finally {
        _ticking = false;
      }
    }
  }

  /// Existing in-process schedule, no new service. Only persisted account opt-ins
  /// are acted on. Stops when app/session closes; not an OS background daemon.
  void startAutomatic() {
    _alive();
    if (_timer != null || _startupTimer != null) return;
    unawaited(_refreshAllCredits());
    _startupTimer = Timer(const Duration(seconds: 30), () {
      _startupTimer = null;
      if (!_closed) unawaited(automaticTick().catchError((_) {}));
    });
    _timer = Timer.periodic(const Duration(minutes: 15), (_) {
      if (!_closed) unawaited(automaticTick().catchError((_) {}));
    });
  }

  Future<void> _refreshAllCredits() async {
    try {
      for (final account in await list()) {
        if (_closed) break;
        try {
          await refreshCredits(account.id);
        } catch (_) {}
      }
    } catch (_) {
      // Storage and authorization errors remain owned by the account service.
    } finally {
      if (!_closed) {
        try {
          await onAutomaticFinished?.call();
        } catch (_) {}
      }
    }
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    unawaited(_changes.close());
    cancelAuthorization();
    _startupTimer?.cancel();
    _timer?.cancel();
    _startupTimer = null;
    _timer = null;
  }
}

String _nonce() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();
bool _unresolved(Object? op) =>
    op is Map && ['pending', 'unknown'].contains(op['state']);
Map<String, dynamic> _match(
  Map<String, dynamic> accounts,
  String id,
  Map<String, dynamic> expected,
) {
  final c = accounts[id];
  if (c is! Map<String, dynamic> ||
      c['generation'] != expected['generation'] ||
      c['accessToken'] != expected['accessToken'])
    throw const MiniMaxAccountError('SourceChanged');
  return c;
}

(String, String) _profile(MiniMaxReply r) {
  if (r.status == 401 || r.status == 403)
    throw const MiniMaxAccountError('NeedsLogin');
  final b = r.body;
  if (r.status < 200 || r.status >= 300 || b == null)
    throw const MiniMaxAccountError('InvalidResponse');
  for (final pair in [('statusInfo', 'code'), ('base_resp', 'status_code')]) {
    final section = b[pair.$1];
    if (section is Map && section.containsKey(pair.$2)) {
      final code = section[pair.$2];
      if (code == 1000048) throw const MiniMaxAccountError('NeedsLogin');
      if (code is! int || code != 0)
        throw const MiniMaxAccountError('InvalidResponse');
    }
  }
  final data = b['data'];
  final p =
      (data is Map ? (data['userInfo'] ?? data['user_info']) : null) ??
      b['userInfo'] ??
      b['user_info'];
  if (p is! Map) throw const MiniMaxAccountError('InvalidResponse');
  final uid = p['realUserID'] ?? p['real_user_id'];
  if (!_validText(uid, 256)) throw const MiniMaxAccountError('InvalidResponse');
  final label =
      p['name'] ?? p['userName'] ?? p['user_name'] ?? p['email'] ?? uid;
  return (
    uid as String,
    _validText(label, 16384)
        ? String.fromCharCodes((label as String).runes.take(160))
        : uid,
  );
}

Map _data(MiniMaxReply r) {
  if (r.status == 401 || r.status == 403)
    throw const MiniMaxAccountError('NeedsLogin');
  final b = r.body;
  if (r.status < 200 ||
      r.status >= 300 ||
      b == null ||
      b['base_resp'] is! Map ||
      (b['base_resp'] as Map)['status_code'] is! int ||
      (b['base_resp'] as Map)['status_code'] != 0 ||
      b['data'] is! Map)
    throw const MiniMaxAccountError('InvalidResponse');
  return b['data'] as Map;
}

bool _finite(Object? n) => n is num && n.isFinite && n >= 0;
String _panel(Map p, {bool automatic = false}) {
  final scene = p['scene'], days = p['days'];
  if (scene is! int ||
      scene < 0 ||
      scene > 4 ||
      days is! List ||
      days.length != 7)
    throw const MiniMaxAccountError('InvalidResponse');
  final numbers = <int>{};
  var claimable = 0, today = 0;
  bool todayClaimed = false, todayClaimable = false;
  for (final d in days) {
    if (d is! Map ||
        d['day_no'] is! int ||
        d['day_no'] < 1 ||
        d['day_no'] > 7 ||
        !numbers.add(d['day_no']) ||
        !_finite(d['points']) ||
        (d['bonus_points'] != null && !_finite(d['bonus_points'])) ||
        d['status'] is! int ||
        d['status'] < 1 ||
        d['status'] > 4 ||
        d['is_today'] is! bool)
      throw const MiniMaxAccountError('InvalidResponse');
    if (d['status'] == 2) claimable++;
    if (d['is_today']) {
      today++;
      todayClaimed = d['status'] == 3;
      todayClaimable = d['status'] == 2;
    }
  }
  if (claimable > 1 || today > 1)
    throw const MiniMaxAccountError('InvalidResponse');
  return todayClaimed
      ? 'alreadyClaimed'
      : claimable == 1 && (!automatic || todayClaimable)
      ? 'claimable'
      : 'unavailable';
}

(String, num, String, int) _receipt(MiniMaxReply r) {
  final d = _data(r);
  if (d['panel'] is! Map) throw const MiniMaxAccountError('InvalidResponse');
  _panel(d['panel']);
  final id = d['claim_id'], result = d['claim_result'], day = d['day_no'];
  if (!_validText(id, 1024) ||
      result is! int ||
      !{1, 2}.contains(result) ||
      day is! int ||
      day < 1 ||
      day > 7 ||
      !_finite(d['points']) ||
      d['expire_at_ms'] is! num ||
      !(d['expire_at_ms'] as num).isFinite)
    throw const MiniMaxAccountError('InvalidResponse');
  return (
    result == 1 ? 'claimed' : 'alreadyClaimed',
    d['points'] as num,
    id as String,
    (d['expire_at_ms'] as num).toInt(),
  );
}

/// Only the user-selected file. No default scanning, version/signature gates or
/// refresh writes. Dart checks ordinary source replacement; hostile same-UID
/// filesystem races require the existing native reader when integrated.
Future<MiniMaxCredential> readMiniMaxCredentialFile(
  String path, {
  required String region,
  required int nowMs,
}) async {
  try {
    final file = File(path);
    if (file.absolute.path != path)
      throw const MiniMaxAccountError('InvalidImport');
    for (var d = file.parent; ; d = d.parent) {
      if (await FileSystemEntity.type(d.path, followLinks: false) !=
          FileSystemEntityType.directory)
        throw const MiniMaxAccountError('InvalidImport');
      if (d.parent.path == d.path) break;
    }
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file)
      throw const MiniMaxAccountError('InvalidImport');
    final before = await file.stat();
    if (before.size > 1048576 || (before.mode & 0x3f) != 0)
      throw const MiniMaxAccountError('InvalidImport');
    final out = BytesBuilder(copy: false);
    await for (final part in file.openRead()) {
      if (out.length + part.length > 1048576)
        throw const MiniMaxAccountError('InvalidImport');
      out.add(part);
    }
    final after = await file.stat();
    if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file ||
        before.size != after.size ||
        before.modified != after.modified ||
        before.changed != after.changed ||
        before.mode != after.mode)
      throw const MiniMaxAccountError('SourceChanged');
    final bytes = out.takeBytes();
    try {
      return MiniMaxCredential.parse(
        bytes,
        sourcePath: path,
        region: region,
        nowMs: nowMs,
      );
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  } on MiniMaxAccountError {
    rethrow;
  } catch (_) {
    throw const MiniMaxAccountError('InvalidImport');
  }
}

const _maxBytes = 1024 * 1024;
bool _safeInt(Object? v) => v is int && v >= 0 && v <= 9007199254740991;
bool _validText(Object? v, int maxBytes) =>
    v is String &&
    v.isNotEmpty &&
    v.trim() == v &&
    utf8.encode(v).length <= maxBytes &&
    !v.runes.any((c) => c < 32 || (c >= 127 && c <= 159));
String _text(Map v, String key, {int maxBytes = 16384}) {
  final value = v[key];
  if (!_validText(value, maxBytes))
    throw const MiniMaxAccountError('InvalidImport');
  return value as String;
}

String _fingerprint(Uint8List bytes) => base64Url.encode(sourceSha256(bytes));
String _sourceHome(String path, _Region region) {
  final suffix =
      '/prod/${region == _Region.cn ? 'cn' : 'en'}/mcode-public/auth.json';
  if (!_validText(path, 4096) ||
      !path.startsWith('/') ||
      !path.endsWith(suffix) ||
      path.contains(r'\'))
    throw const MiniMaxAccountError('UnsupportedSource');
  final parts = path.substring(1).split('/');
  if (parts.any((p) => p.isEmpty || p == '.' || p == '..'))
    throw const MiniMaxAccountError('UnsupportedSource');
  final home = path.substring(0, path.length - suffix.length);
  if (home.isEmpty) throw const MiniMaxAccountError('UnsupportedSource');
  return home;
}

MiniMaxCredential _parseCandidate(
  Uint8List bytes,
  String path,
  _Region region,
  int nowMs,
) {
  if (bytes.length > _maxBytes)
    throw const MiniMaxAccountError('InvalidImport');
  final home = _sourceHome(path, region);
  Map v;
  try {
    final raw = utf8.decode(bytes);
    _rejectDuplicateKeys(raw);
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException();
    v = decoded;
  } on FormatException {
    throw const MiniMaxAccountError('InvalidImport');
  }
  if (v['schemaVersion'] is! int ||
      v['schemaVersion'] != 1 ||
      v['records'] is! Map)
    throw const MiniMaxAccountError('InvalidImport');
  final account = base64Url
      .encode(sourceSha256(utf8.encode('$home\u0000mcode-public')))
      .replaceAll('=', '');
  final key =
      'com.minimax.mcode.oauth.prod.${region == _Region.cn ? 'cn' : 'en'}\u0000$account';
  final c = (v['records'] as Map)[key];
  if (c == null) throw const MiniMaxAccountError('SourceMismatch');
  if (c is! Map || c['schemaVersion'] is! int || c['schemaVersion'] != 1)
    throw const MiniMaxAccountError('InvalidImport');
  if (_text(c, 'clientId') != 'mcode-public' ||
      _text(c, 'audience') != 'agent-backend' ||
      _text(c, 'tokenType') != 'Bearer')
    throw const MiniMaxAccountError('SourceMismatch');
  final scopes = c['scopes'];
  if (scopes is! List || !scopes.every((v) => v is String))
    throw const MiniMaxAccountError('InvalidImport');
  if (!scopes.contains('agent.default'))
    throw const MiniMaxAccountError('SourceMismatch');
  final accessToken = _text(c, 'accessToken');
  _text(c, 'refreshToken'); // Validate format only; never retain or refresh it.
  final generation = c['generation'], expiry = c['expiresAtMs'];
  if (!_safeInt(generation) || !_safeInt(expiry))
    throw const MiniMaxAccountError('InvalidImport');
  if ((expiry as int) <= nowMs) throw const MiniMaxAccountError('NeedsLogin');
  if (c.containsKey('subject')) {
    _text(c, 'subject', maxBytes: 256);
  }
  if (c.containsKey('accountId')) _text(c, 'accountId');
  if (c.containsKey('loginEpoch')) _text(c, 'loginEpoch');
  return MiniMaxCredential._(
    region == _Region.cn ? 'cn' : 'global',
    _fingerprint(
      Uint8List.fromList([
        ...utf8.encode('$path\u0000${region.name}\u0000'),
        ...bytes,
      ]),
    ),
    accessToken,
    generation as int,
    expiry,
  );
}

// Reject ambiguous JSON keys before dart:convert's last-key-wins decoding.
// Adapted from LoongPass's strict Qoder decoder; bounded iterative scan.
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
        if (stack.isEmpty || stack.last == null || !stack.last!.add(key))
          throw const FormatException();
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
