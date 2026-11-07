import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'account_document_store.dart';
import 'account_registration.dart';
import 'claim_receipt.dart';
import 'source_digest.dart';
import 'zcode_api.dart';
import 'zcode_rewards.dart';

class ZcodeActivityAccount {
  final String id, uid, family, label, status, deviceSuffix;
  final bool automatic;
  final String? registrationId;
  final int? checkedAt;
  final ClaimReceipt? latestClaim;
  final List<ZcodeBucket> buckets;
  ZcodeActivityAccount(Map<String, dynamic> a)
    : id = a['id'],
      registrationId = a['registrationId'],
      uid = a['uid'],
      family = a['family'],
      label = a['label'],
      status = a['status'],
      deviceSuffix = (a['context']['deviceMid'] as String).substring(30),
      automatic = a['automatic'],
      checkedAt = a['checkedAt'],
      latestClaim = _latestClaim(a),
      buckets = [
        for (final b in a['buckets'] as List)
          ZcodeBucket.fromJson(Map<String, dynamic>.from(b)),
      ];
  static ClaimReceipt? _latestClaim(Map<String, dynamic> account) {
    // These receipts confirm an entitlement, not an awarded amount or instant.
    // Submission and plan-expiry times must not become receipt timestamps.
    final histories = [
      account['claims'],
      for (final binding in account['bindingHistory'] ?? const [])
        binding['claims'],
    ];
    for (final claims in histories) {
      if (claims is Map &&
          claims.values.any((c) => c is Map && c['state'] == 'claimed')) {
        return const ClaimReceipt();
      }
    }
    return null;
  }

  @override
  String toString() => 'ZcodeActivityAccount([redacted])';
}

class _Login {
  final String family, pollToken;
  final Map<String, String> context;
  final String? accountId;
  final String? originalDevice;
  final bool replaceDevice;
  String? flow;
  int expires = 0, interval = 1, nextPoll = 0;
  Map<String, dynamic>? ready;
  bool committing = false;
  _Login(
    this.family,
    this.pollToken,
    this.context,
    this.accountId,
    this.replaceDevice,
    this.originalDevice,
  );
}

/// One ephemeral authorization owned by the saved-account transaction.
class ZcodeInferenceAuthorization {
  final String token, registrationId;
  final Map<String, String> context;
  final bool Function() isCurrent;
  final Future<Map<String, dynamic>> Function() balance, clientConfig;
  ZcodeInferenceAuthorization._(
    this.token,
    this.registrationId,
    this.context,
    this.isCurrent,
    this.balance,
    this.clientConfig,
  );
  @override
  String toString() => 'ZcodeInferenceAuthorization(redacted)';
}

/// Sole owner of saved identities, authorization recovery, durable activity
/// attempts and scheduling. Presentation reads never trigger network work.
class ZcodeActivityAccounts {
  final AccountDocumentStore store;
  final ZcodeApi api;
  final int Function() now;
  final Future<String?> Function(ZcodeCaptchaConfig)? requestVerification;
  final _authorizationChanges = StreamController<void>.broadcast();
  Stream<void> get authorizationChanges => _authorizationChanges.stream;
  FutureOr<void> Function()? onChanged;
  static final _writers = <String>{};
  bool _closed = false;
  _Login? _login;
  Timer? _poll, _startup, _timer;
  String? message;
  String? authorizationError;
  bool get loginPending => _login != null;
  ZcodeActivityAccounts({
    required this.store,
    required this.api,
    this.requestVerification,
    int Function()? now,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  void _alive() {
    if (_closed) throw const ZcodeFailure('closed');
  }

  Future<void> _notify() async {
    if (!_closed) {
      try {
        await onChanged?.call();
      } catch (_) {}
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    _alive();
    if (!_writers.add(store.identity)) throw const ZcodeFailure('busy');
    try {
      return await action();
    } finally {
      _writers.remove(store.identity);
      await _notify();
    }
  }

  Future<AccountDocument> _read() async {
    try {
      final doc = await store.read();
      if (doc.data.isEmpty)
        doc.data.addAll({'version': 1, 'accounts': <String, dynamic>{}});
      if (doc.data['version'] != 1 ||
          doc.data['accounts'] is! Map<String, dynamic>)
        throw const FormatException();
      final pool = doc.data['devicePool'] ?? <String>[];
      if (pool is! List ||
          pool.length > 100 ||
          pool.any((v) => zcodeDeviceId(v) != v) ||
          pool.toSet().length != pool.length)
        throw const FormatException();
      for (final e in (doc.data['accounts'] as Map<String, dynamic>).entries) {
        final a = e.value;
        if (a is! Map<String, dynamic> ||
            a['id'] != e.key ||
            !{'bigmodel', 'zai'}.contains(a['family']) ||
            !zcodeText(a['uid']) ||
            !zcodeText(a['label']) ||
            !zcodeText(a['token'], 16384) ||
            a['automatic'] is! bool ||
            a['registrationId'] != null && !zcodeText(a['registrationId']) ||
            a['claims'] is! Map<String, dynamic> ||
            a['buckets'] is! List ||
            !_statuses.contains(a['status']))
          throw const FormatException();
        zcodeContext(Map<String, dynamic>.from(a['context']));
        final history = a['bindingHistory'] ?? <dynamic>[];
        if (history is! List) throw const FormatException();
        for (final previous in history) {
          if (previous is! Map ||
              previous['claims'] is! Map ||
              previous['changedAt'] is! int)
            throw const FormatException();
          zcodeContext(Map<String, dynamic>.from(previous['context']));
        }
        if (_id(a['family'], a['uid']) != a['id'])
          throw const FormatException();
        for (final c in (a['claims'] as Map).values) {
          if (c is! Map ||
              !_claimStates.contains(c['state']) ||
              c['previous'] is! List ||
              !(c['previous'] as List).every((v) => zcodeText(v)))
            throw const FormatException();
        }
      }
      return doc;
    } catch (_) {
      throw const ZcodeFailure('storage_unavailable');
    }
  }

  Future<void> _write(AccountDocument doc) async {
    _alive();
    try {
      await store.write(doc.revision, doc.data);
    } catch (_) {
      throw const ZcodeFailure('storage_unavailable');
    }
  }

  static const _claimStates = {
    'pending',
    'claimed',
    'verificationRequired',
    'activationRequired',
    'ineligible',
  };
  static const _statuses = {
    'unavailable',
    'claimable',
    'claimed',
    'observedClaimed',
    'noOffer',
    'pending',
    'verificationRequired',
    'activationRequired',
    'ineligible',
    'authorization_required',
    'discoveryIncomplete',
  };
  static String _id(String family, String uid) => sourceSha256(
    utf8.encode('$family\u0000$uid'),
  ).map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  Future<List<ZcodeActivityAccount>> accounts() async => [
    for (final a in ((await _read()).data['accounts'] as Map).values)
      ZcodeActivityAccount(a),
  ];

  static Set<String> _occupied(
    Map<String, dynamic> data, {
    String? except,
    bool includeHistory = true,
  }) => {
    for (final entry in (data['accounts'] as Map).entries) ...{
      if (entry.key != except)
        zcodeDeviceId(entry.value['context']['deviceMid']),
      for (final old
          in includeHistory ? entry.value['bindingHistory'] ?? [] : [])
        zcodeDeviceId(old['context']['deviceMid']),
    },
  };

  static List<String> _available(Map<String, dynamic> data) {
    final occupied = _occupied(data);
    return [
      for (final id in data['devicePool'] ?? [])
        if (!occupied.contains(id)) id as String,
    ];
  }

  Future<int> availableDeviceCount() async =>
      _available((await _read()).data).length;

  static String _newDeviceId(Set<String> occupied) {
    final random = Random.secure();
    while (true) {
      final bytes = List.generate(16, (_) => random.nextInt(256));
      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;
      final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final id =
          '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
          '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
      if (!occupied.contains(id)) return id;
    }
  }

  Future<Uri> beginAuthorization(
    String family,
    Map<String, dynamic> context, {
    String? accountId,
    bool replaceDevice = false,
  }) => _exclusive(() async {
    if (!{'bigmodel', 'zai'}.contains(family))
      throw const ZcodeFailure('invalid_provider');
    if (_login != null) throw const ZcodeFailure('busy');
    authorizationError = null;
    final doc = await _read();
    final target = accountId == null
        ? null
        : (doc.data['accounts'] as Map)[accountId];
    if (accountId != null && (target == null || target['family'] != family))
      throw const ZcodeFailure('account_missing');
    if (replaceDevice && target == null)
      throw const ZcodeFailure('account_missing');
    final selected = zcodeContext(context);
    final available = _available(doc.data);
    if (target != null && !replaceDevice) {
      selected['deviceMid'] = zcodeDeviceId(target['context']['deviceMid']);
    } else {
      if (replaceDevice && available.isEmpty)
        throw const ZcodeFailure('device_pool_empty');
      selected['deviceMid'] = available.isNotEmpty
          ? available.first
          : zcodeDeviceId(selected['deviceMid']);
      final occupied = _occupied(doc.data);
      if (occupied.contains(selected['deviceMid'])) {
        // Freeze this allocation in _Login; only a verified account persists it.
        selected['deviceMid'] = _newDeviceId(occupied);
      }
    }
    final random = Random.secure();
    final token = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final login = _Login(
      family,
      token,
      selected,
      accountId,
      replaceDevice,
      target == null ? null : zcodeDeviceId(target['context']['deviceMid']),
    );
    _login = login;
    try {
      final d = zcodeData(
        await api.request(
          ZcodeApi.initPath,
          token,
          login.context,
          body: {'provider': family},
          isCurrent: () => !_closed && identical(_login, login),
        ),
      );
      final url = d['authorize_url'] is String
          ? Uri.tryParse(d['authorize_url'])
          : null;
      final hosts = family == 'bigmodel'
          ? {'bigmodel.cn', 'zcode.z.ai'}
          : {'z.ai', 'zcode.z.ai'};
      if (url == null ||
          url.scheme != 'https' ||
          !hosts.contains(url.host) ||
          url.userInfo.isNotEmpty ||
          url.port != 443 ||
          url.fragment.isNotEmpty ||
          !zcodeText(d['flow_id']) ||
          !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(d['flow_id']) ||
          d['expires_at'] is! int ||
          d['expires_at'] * 1000 <= now() ||
          d['poll_interval_sec'] is! int ||
          d['poll_interval_sec'] < 1 ||
          d['poll_interval_sec'] > 300) {
        throw const ZcodeFailure('invalid_response');
      }
      login.flow = d['flow_id'];
      login.expires = min(d['expires_at'] * 1000 as int, now() + 600000);
      login.interval = d['poll_interval_sec'];
      message = '请在智谱官方页面完成授权，完成后会自动保存。';
      return url;
    } catch (_) {
      if (identical(_login, login)) _login = null;
      rethrow;
    }
  });
  void followAuthorization() {
    _alive();
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        await pollAuthorizationOnce();
      } on ZcodeFailure catch (e) {
        if (e.code != 'busy')
          if (loginPending) {
            message = '授权结果保留中，正在重试保存或等待官网。';
          } else {
            authorizationError = e.code;
          }
        await _notify();
      }
    });
  }

  Future<void> pollAuthorizationOnce() => _exclusive(() async {
    final login = _login;
    if (login == null || login.flow == null) return;
    if (login.ready == null) {
      if (now() >= login.expires) {
        _endAuthorization();
        throw const ZcodeFailure('authorization_expired');
      }
      if (now() < login.nextPoll) return;
      login.nextPoll = now() + login.interval * 1000;
      final d = zcodeData(
        await api.request(
          '${ZcodeApi.pollPrefix}${login.flow}',
          login.pollToken,
          login.context,
          isCurrent: () => !_closed && identical(_login, login),
        ),
      );
      if (d['status'] == 'pending') return;
      if (d['status'] == 'failed') {
        _endAuthorization();
        throw const ZcodeFailure('authorization_failed');
      }
      final user = d['user'];
      if (d['status'] != 'ready' ||
          user is! Map ||
          !zcodeText(user['user_id']) ||
          !zcodeText(d['token'], 16384) ||
          d[login.family] is! Map)
        throw const ZcodeFailure('invalid_response');
      login.ready = {
        'uid': user['user_id'],
        'label': zcodeText(user['name'])
            ? user['name']
            : zcodeText(user['email'])
            ? user['email']
            : user['user_id'],
        'token': d['token'],
      };
    }
    final ready = login.ready!;
    final doc = await _read(),
        map = doc.data['accounts'] as Map<String, dynamic>;
    if (_closed || !identical(_login, login)) return;
    final id = _id(login.family, ready['uid']),
        old = map[id] as Map<String, dynamic>?;
    if (login.accountId != null && login.accountId != id) {
      _endAuthorization();
      throw const ZcodeFailure('account_mismatch');
    }
    if (login.accountId != null &&
        (old == null ||
            (zcodeDeviceId(old['context']['deviceMid']) !=
                    login.originalDevice &&
                !(old['context']['deviceMid'] == login.context['deviceMid'] &&
                    old['token'] == ready['token'])))) {
      _endAuthorization();
      throw const ZcodeFailure('binding_changed');
    }
    final deviceChanged =
        old != null &&
        zcodeDeviceId(old['context']['deviceMid']) !=
            login.context['deviceMid'];
    if (deviceChanged && !login.replaceDevice) {
      _endAuthorization();
      throw const ZcodeFailure('device_rebind_required');
    }
    if (_occupied(
      doc.data,
      except: id,
      includeHistory: deviceChanged || old == null,
    ).contains(login.context['deviceMid'])) {
      _endAuthorization();
      throw const ZcodeFailure('device_in_use');
    }
    map[id] = {
      ...?old,
      'id': id,
      ...ready,
      'family': login.family,
      'context': login.context,
      'registrationId': deviceChanged
          ? newAccountRegistrationId()
          : old?['registrationId'] ?? newAccountRegistrationId(),
      'automatic': old?['automatic'] ?? true,
      'status': deviceChanged || old?['status'] == 'authorization_required'
          ? 'unavailable'
          : old?['status'] ?? 'unavailable',
      'claims': deviceChanged
          ? <String, dynamic>{}
          : old?['claims'] ?? <String, dynamic>{},
      if (deviceChanged)
        'bindingHistory': [
          ...?old['bindingHistory'],
          {
            'context': old['context'],
            'claims': old['claims'],
            'changedAt': now(),
          },
        ],
      'buckets': old?['buckets'] ?? [],
    };
    login.committing = true;
    await _write(doc);
    // A lost acknowledgement may follow a successful atomic commit. Keep
    // cancellation disabled on failure until the retained grant is reconciled.
    login.committing = false;
    _alive();
    if (identical(_login, login)) {
      _login = null;
      _poll?.cancel();
    }
    if (!_closed) _authorizationChanges.add(null);
    message = '账号已保存；自动检查活动已开启。';
    startAutomatic();
  });
  bool cancelAuthorization() {
    if (_login?.committing == true) return false;
    _endAuthorization();
    return true;
  }

  void _endAuthorization() {
    _login = null;
    authorizationError = null;
    _poll?.cancel();
    _poll = null;
  }

  Future<Map<String, dynamic>> _request(
    String path,
    Map<String, dynamic> a, {
    Map<String, dynamic>? body,
    ZcodeVerification? verification,
  }) => api.request(
    path,
    a['token'],
    zcodeContext(Map<String, dynamic>.from(a['context'])),
    body: body,
    verification: verification,
    isCurrent: () => !_closed,
  );
  Future<ZcodeBalance> _balance(Map<String, dynamic> a) async =>
      ZcodeBalance.parse(await _request(ZcodeApi.balancePath, a), now());
  static void _observe(Map<String, dynamic> a, ZcodeBalance b) {
    a['buckets'] = b.buckets.map((v) => v.toJson()).toList();
    a['checkedAt'] = b.checkedAt;
  }

  Future<T> withInferenceAuthorization<T>(
    String id,
    Future<T> Function(ZcodeInferenceAuthorization) use, {
    String? expectedRegistrationId,
  }) => _exclusive(() async {
    final doc = await _read();
    final a = (doc.data['accounts'] as Map)[id];
    if (a is! Map<String, dynamic> || a['family'] != 'bigmodel')
      throw const ZcodeFailure('account_missing');
    if (a['registrationId'] == null) {
      a['registrationId'] = newAccountRegistrationId();
      await _write(doc);
    }
    if (expectedRegistrationId != null &&
        a['registrationId'] != expectedRegistrationId)
      throw const ZcodeFailure('binding_changed');
    var active = true;
    bool current() => active && !_closed;
    Future<Map<String, dynamic>> read(String path) => api.request(
      path,
      a['token'],
      zcodeContext(Map<String, dynamic>.from(a['context'])),
      isCurrent: current,
    );
    try {
      return await use(
        ZcodeInferenceAuthorization._(
          a['token'],
          a['registrationId'],
          Map.unmodifiable(
            zcodeContext(Map<String, dynamic>.from(a['context'])),
          ),
          current,
          () async {
            final response = await read(ZcodeApi.balancePath);
            final parsed = ZcodeBalance.parse(response, now());
            _observe(a, parsed);
            await _write(doc);
            return response;
          },
          () => read(ZcodeApi.configPath),
        ),
      );
    } finally {
      active = false;
    }
  });

  static void _confirmed(Map<String, dynamic> c, Map<String, dynamic> plan) {
    c['state'] = 'claimed';
    c['instance'] = plan['user_plan_id'];
    c['endsAt'] = plan['ends_at'];
  }

  static String? _rejection(Map c) {
    final http = c['httpStatus'], code = c['serviceCode'];
    if ((http == 200 || http == 400) && code == 3007)
      return 'verificationRequired';
    if (http != 200) return null;
    return switch (code) {
      1004 => 'activationRequired',
      1001 || 1002 || 1003 || 1005 || 3001 => 'ineligible',
      _ => null,
    };
  }

  Future<void> inspect(String id) => _exclusive(() => _run(id, submit: false));
  Future<void> _refreshCredits(String id) async {
    final doc = await _read();
    final account = (doc.data['accounts'] as Map)[id] as Map<String, dynamic>?;
    if (account == null) throw const ZcodeFailure('account_missing');
    _observe(account, await _balance(account));
    await _write(doc);
  }

  Future<void> _refreshAllCredits() async {
    if (_closed || _writers.contains(store.identity) || loginPending) return;
    await _exclusive(() async {
      for (final account in await accounts()) {
        if (_closed) break;
        try {
          await _refreshCredits(account.id);
        } on ZcodeFailure catch (e) {
          if (e.code == 'storage_unavailable') rethrow;
        }
      }
    });
  }

  Future<void> claim(
    String id, {
    Future<String?> Function(ZcodeCaptchaConfig)? verify,
  }) => _exclusive(() => _run(id, submit: true, verify: verify));
  Future<void> _run(
    String id, {
    required bool submit,
    bool automatic = false,
    Future<String?> Function(ZcodeCaptchaConfig)? verify,
  }) async {
    verify ??= requestVerification;
    var doc = await _read();
    var a = (doc.data['accounts'] as Map)[id] as Map<String, dynamic>?;
    if (a == null) throw const ZcodeFailure('account_missing');
    if (automatic &&
        (!a['automatic'] || a['status'] == 'authorization_required'))
      return;
    var claims = a['claims'] as Map<String, dynamic>;
    try {
      // Earlier candidates persisted numeric rejection evidence as uncertain.
      // Only a definite rejection may leave pending without a balance receipt.
      for (final c in claims.values) {
        if (c['state'] == 'pending' && _rejection(c) != null)
          c['state'] = _rejection(c);
      }
      var balance = await _balance(a);
      _observe(a, balance);
      var unresolved = false, reconciled = false;
      for (final e in claims.entries) {
        final c = e.value as Map<String, dynamic>;
        if (c['state'] != 'pending') continue;
        final receipt = balance.receipt(e.key, c['previous']);
        if (receipt != null) {
          _confirmed(c, receipt);
          reconciled = true;
        } else {
          unresolved = true;
        }
      }
      if (unresolved || reconciled) {
        a['status'] = unresolved ? 'pending' : 'claimed';
        await _write(doc);
        return;
      }
      final offers = <String, ZcodeOffer>{};
      var complete = true;
      for (final source in [
        (ZcodeApi.previewPath, zcodePreviewOffers),
        (ZcodeApi.marketingPath, zcodeMarketingOffers),
      ]) {
        try {
          for (final offer in source.$2(await _request(source.$1, a))) {
            offers.putIfAbsent(offer.id, () => offer);
          }
        } on ZcodeFailure catch (e) {
          if ({
            'authorization_required',
            'cancelled',
            'closed',
          }.contains(e.code))
            rethrow;
          // The sources are independent: a missing preview must not suppress a
          // concrete marketing offer. Incomplete discovery never means no offer.
          complete = false;
        }
      }
      final sorted = offers.values.toList()
        ..sort((a, b) => b.priority.compareTo(a.priority));
      ZcodeOffer? selected;
      String? pause;
      var held = false;
      for (final offer in sorted) {
        if (balance.active(offer.id) != null) {
          held = true;
          continue;
        }
        final c = claims[offer.id] as Map?;
        if (c?['state'] == 'claimed' &&
            (c?['endsAt'] is! int || c!['endsAt'] > balance.serverTime)) {
          held = true;
          continue;
        }
        if (c?['state'] == 'verificationRequired' ||
            c?['state'] == 'activationRequired') {
          pause ??= c!['state'];
          if (automatic || !submit) continue;
        }
        selected = offer;
        break;
      }
      if (selected == null) {
        a['status'] =
            pause ??
            (held
                ? 'observedClaimed'
                : complete
                ? 'noOffer'
                : 'discoveryIncomplete');
        await _write(doc);
        return;
      }
      a['status'] = 'claimable';
      if (!submit) {
        await _write(doc);
        return;
      }
      if (_occupied(
        doc.data,
        except: id,
        includeHistory: false,
      ).contains(zcodeDeviceId(a['context']['deviceMid'])))
        throw const ZcodeFailure('device_in_use');
      // An unverified attempt and at most one fresh human-verified attempt.
      for (var attempt = 0; attempt < 2; attempt++) {
        ZcodeVerification? verification;
        if (claims[selected.id]?['state'] == 'verificationRequired') {
          a!['status'] = 'verificationRequired';
          await _write(doc);
          doc = await _read();
          a = (doc.data['accounts'] as Map)[id];
          claims = a!['claims'];
          if (verify == null) return;
          final config = ZcodeCaptchaConfig.parse(
            await _request(ZcodeApi.configPath, a),
          );
          final proof = await verify(config);
          _alive();
          if (proof == null) return;
          verification = ZcodeVerification(proof, config.values['region']!);
          // The official client may have granted the plan during human interaction.
          balance = await _balance(a);
          _observe(a, balance);
          if (balance.active(selected.id) != null) {
            _confirmed(claims[selected.id], balance.active(selected.id)!);
            a['status'] = 'observedClaimed';
            await _write(doc);
            return;
          }
        }
        final c = <String, dynamic>{
          'state': 'pending',
          'previous': [for (final p in balance.plans) p['user_plan_id']],
          'submittedAt': now(),
        };
        claims[selected.id] = c;
        a!['status'] = 'pending';
        await _write(doc); // Durable intent must precede every possible POST.
        // Continue from a fresh CAS revision, retaining the same credential owner.
        doc = await _read();
        a = (doc.data['accounts'] as Map)[id];
        claims = a!['claims'];
        final current = claims[selected.id] as Map<String, dynamic>;
        try {
          final reply = await _request(
            ZcodeApi.claimPath,
            a,
            body: {'plan_id': selected.id},
            verification: verification,
          );
          current['httpStatus'] = 200;
          current['serviceCode'] = zcodeCode(reply);
        } on ZcodeFailure catch (e) {
          current['errorCode'] = e.code;
          current['httpStatus'] = e.httpStatus;
          current['serviceCode'] = e.serviceCode;
          if (e.code == 'authorization_required') {
            // A definite authorization rejection did not grant an entitlement.
            // It must not turn into a permanent uncertain POST after re-login.
            current['state'] = 'ineligible';
            a['status'] = 'authorization_required';
          }
        }
        current['state'] = _rejection(current) ?? current['state'];
        try {
          balance = await _balance(a);
          _observe(a, balance);
          final receipt = balance.receipt(selected.id, current['previous']);
          if (receipt != null)
            _confirmed(current, receipt);
          else if (current['state'] == 'ineligible' &&
              balance.active(selected.id) != null) {
            _confirmed(current, balance.active(selected.id)!);
          }
        } on ZcodeFailure {
          /* Keep the durable outcome and original observation. */
        }
        if (a['status'] != 'authorization_required')
          a['status'] = current['state'];
        await _write(doc);
        if (current['state'] != 'verificationRequired' ||
            verify == null ||
            verification != null)
          return;
        doc = await _read();
        a = (doc.data['accounts'] as Map)[id];
        claims = a!['claims'];
      }
    } on ZcodeFailure catch (e) {
      // If publication may have succeeded, never overwrite it from this stale
      // snapshot. The next invocation reads and reconciles the durable journal.
      if (e.code == 'storage_unavailable' ||
          e.code == 'closed' ||
          e.code == 'cancelled')
        rethrow;
      a!['status'] = claims.values.any((v) => v['state'] == 'pending')
          ? 'pending'
          : e.code == 'authorization_required'
          ? 'authorization_required'
          : claims.values.any((v) => v['state'] == 'verificationRequired')
          ? 'verificationRequired'
          : 'unavailable';
      await _write(doc);
      rethrow;
    }
  }

  Future<void> setAutomatic(String id, bool enabled) => _exclusive(() async {
    final doc = await _read(), a = (doc.data['accounts'] as Map)[id];
    if (a == null) throw const ZcodeFailure('account_missing');
    a['automatic'] = enabled;
    await _write(doc);
  });
  Future<void> tick() async {
    if (_closed || _writers.contains(store.identity) || loginPending) return;
    await _exclusive(() async {
      for (final a in await accounts()) {
        if (_closed) break;
        try {
          if (a.automatic) {
            await _run(a.id, submit: true, automatic: true);
          } else {
            await _refreshCredits(a.id);
          }
        } on ZcodeFailure catch (e) {
          if (e.code == 'storage_unavailable') rethrow;
        }
      }
    });
  }

  void startAutomatic() {
    _alive();
    if (_timer != null) return;
    unawaited(_refreshAllCredits().catchError((_) {}));
    Future<void> run() async {
      try {
        await tick();
      } catch (_) {}
    }

    _startup = Timer(const Duration(seconds: 30), run);
    _timer = Timer.periodic(
      const Duration(minutes: 10),
      (_) => unawaited(run()),
    );
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    unawaited(_authorizationChanges.close());
    _login = null;
    _poll?.cancel();
    _startup?.cancel();
    _timer?.cancel();
  }
}
