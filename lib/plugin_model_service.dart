import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'plugin_accounts.dart';
import 'account_document_store.dart';
import 'plugin_runtime.dart';

class PluginModelGrant {
  PluginModelGrant(this.account, this.token, this.enabled);
  final PluginAccount account;
  final String token;
  final bool enabled;
}

/// Local capability boundary. Request conversion, recovery and supplier
/// credentials belong to the two native Magpie hosts on either side.
class PluginModelService extends ChangeNotifier {
  PluginModelService({
    required this.accounts,
    required this.store,
    this.port = 3426,
  });
  final PluginAccounts accounts;
  final AccountDocumentStore store;
  final int port;
  Map<String, dynamic> _data = {};
  Future<void> _writes = Future.value();
  HttpServer? _server;
  final _active = <PluginFetch, PluginModelGrant>{};
  bool _closed = false;
  String? error;
  bool get enabled => _data['enabled'] == true;
  bool get running => _server != null;
  Uri? get endpoint => _server == null
      ? null
      : Uri(scheme: 'http', host: '127.0.0.1', port: _server!.port);
  Set<String> get legacyKeys => {
    for (final key in _data['legacyKeys'] as List? ?? const [])
      if (key is String && key.isNotEmpty) key,
  };
  Future<void> saveConnectionBackup(List<Map<String, dynamic>> rows) =>
      _edit((data) {
        final backups = data.putIfAbsent('retiredConnections', () => {}) as Map;
        for (final row in rows) backups.putIfAbsent(row['id'], () => row);
      });
  Map get _rows => _data['grants'] as Map? ?? {};
  List<PluginModelGrant> get grants => List.unmodifiable([
    for (final account in accounts.accounts)
      PluginModelGrant(
        account,
        _rows[account.key]?['token'] ?? '',
        _rows[account.key]?['enabled'] == true &&
            _rows[account.key]?['registrationId'] == account.registrationId,
      ),
  ]);

  Future<void> start() async {
    final saved = await store.read();
    _data = saved.data;
    if (_data['version'] != 4) {
      if (_data.isNotEmpty && !{1, 2, 3}.contains(_data['version']))
        throw StateError('Unsupported model settings');
      final rows = <String, dynamic>{};
      for (final account in accounts.accounts) {
        final legacy = (_data['bindings'] as Map? ?? {}).values.where(
          (v) =>
              v['accountId'] == account.facts['sourceId'] &&
              v['providerId'] == _legacyProvider(account.facts['sourceScope']),
        );
        if (legacy.isEmpty) continue;
        final old = legacy.first;
        rows[account.key] = {
          'token': old['key'],
          'enabled': old['enabled'] == true,
          'registrationId': old['registrationId'],
        };
      }
      _data = {
        'version': 4,
        'enabled': _data['enabled'] == true,
        'grants': rows,
        'legacyKeys': [
          if (_data['poolKey'] is String) _data['poolKey'],
          for (final row in (_data['bindings'] as Map? ?? {}).values)
            if (row['key'] is String) row['key'],
        ],
      };
      await store.write(saved.revision, _data);
    }
    accounts.addListener(_changed);
    if (enabled) {
      try {
        await _listen();
      } on SocketException {
        error = 'listener_unavailable';
      }
    }
  }

  static String? _legacyProvider(Object? scope) => switch (scope) {
    'MiniMax-cn' => 'minimax-cn',
    'MiniMax-global' => 'minimax-global',
    'Qoder-cn' => 'qoder-cn',
    'WorkBuddy' => 'workbuddy-cn',
    'ZCode' => 'zcode-bigmodel',
    'RewardChannels' => 'loomy',
    _ => null,
  };
  static String _token() =>
      base64UrlEncode(List.generate(32, (_) => Random.secure().nextInt(256)))
          .replaceAll('=', '');

  Future<void> _edit(void Function(Map<String, dynamic>) change) {
    final next = _writes.then((_) async {
      if (_closed) throw StateError('Model service closed');
      final doc = await store.read();
      change(doc.data);
      try {
        await store.write(doc.revision, doc.data);
      } catch (_) {
        try {
          _data = (await store.read()).data;
        } catch (_) {
          _data = {'version': 4, 'enabled': false, 'grants': {}};
          error = 'settings_unavailable';
        }
        _changed();
        rethrow;
      }
      _data = doc.data;
      _changed();
    });
    _writes = next.catchError((_) {});
    return next;
  }

  Future<void> enable(String key, bool value) => _edit((data) {
    final account = accounts.accounts.singleWhere((a) => a.key == key);
    final rows = data['grants'] as Map;
    final old = rows[key] as Map?;
    rows[key] = {
      'token': old?['registrationId'] == account.registrationId
          ? old!['token']
          : _token(),
      'enabled': value,
      'registrationId': account.registrationId,
    };
  });
  Future<void> setEnabled(bool value) async {
    await _edit((data) => data['enabled'] = value);
    if (value) {
      await _listen();
    } else {
      await _stop();
    }
    notifyListeners();
  }

  Future<void> _listen() async {
    if (_server != null || _closed) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    if (_closed || !enabled) {
      await server.close(force: true);
      return;
    }
    _server = server;
    error = null;
    _server!.autoCompress = false;
    _server!.idleTimeout = const Duration(seconds: 30);
    _server!.listen(
      (r) => unawaited(_handle(r)),
      onError: (_) {
        error = 'listener_unavailable';
        if (!_closed) notifyListeners();
      },
    );
  }

  bool _current(PluginModelGrant grant) =>
      !_closed &&
      enabled &&
      accounts.accounts.any(
        (a) =>
            a.key == grant.account.key &&
            a.active &&
            a.registrationId == grant.account.registrationId,
      ) &&
      _rows[grant.account.key]?['enabled'] == true &&
      _rows[grant.account.key]?['token'] == grant.token &&
      _rows[grant.account.key]?['registrationId'] ==
          grant.account.registrationId;
  void _changed() {
    if (_closed) return;
    for (final entry in _active.entries.toList()) {
      if (!_current(entry.value)) unawaited(entry.key.cancel());
    }
    if (!enabled) unawaited(_stop());
    notifyListeners();
  }

  static bool _same(String a, String b) {
    var difference = a.length ^ b.length;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ (i < b.length ? b.codeUnitAt(i) : 0);
    }
    return difference == 0;
  }

  PluginModelGrant? _authorize(HttpRequest request) {
    final header = request.headers.value('authorization') ?? '';
    if (!header.startsWith('Bearer ') || header.length > 1024) return null;
    final token = header.substring(7);
    for (final grant in grants) {
      if (grant.token.isNotEmpty &&
          _same(grant.token, token) &&
          _current(grant))
        return grant;
    }
    return null;
  }

  Future<void> _json(HttpResponse response, int status, Object body) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  Future<void> _handle(HttpRequest request) async {
    PluginFetch? fetch;
    var headed = false;
    try {
      if (request.headers.value('origin') != null) {
        await _json(request.response, 403, {
          'error': 'browser_origin_not_allowed',
        });
        return;
      }
      final grant = _authorize(request);
      if (grant == null) {
        await _json(request.response, 401, {'error': 'grant_unavailable'});
        return;
      }
      final account = grant.account;
      final limits = accounts.providers[account.provider] ?? {};
      if (request.method == 'GET' && request.uri.path == '/plugin/catalog') {
        await _json(request.response, 200, {
          'account': {
            'id': account.key,
            'provider': account.provider,
            'label': account.label,
          },
          'models': _supportedModels(account).toList(),
          'usage': account.usage,
          'maxConcurrency': limits['maxConcurrency'] ?? 0,
          'maxAccounts': limits['maxAccounts'] ?? 0,
        });
        return;
      }
      if (request.method != 'POST' || request.uri.path != '/plugin/fetch') {
        await _json(request.response, 410, {
          'error': 'native_plugin_required',
          'message': 'Connect the LoongPass native Magpie plugin.',
        });
        return;
      }
      final bytes = <int>[];
      await for (final chunk in request.timeout(const Duration(seconds: 30))) {
        if (bytes.length + chunk.length > 32 << 20)
          throw const FormatException('Request too large');
        bytes.addAll(chunk);
      }
      final body = jsonDecode(utf8.decode(bytes)) as Map;
      final model = _supportedModels(account)
          .where(
            (m) =>
                // Magpie's native Go boundary sends api.id to its host, while
                // OpenCode can retain the catalog id. Both name this account's
                // declared model; the SDK and URL disambiguate native aliases.
                (m['apiId'] == body['model'] ||
                    '${account.provider}/${m['id']}' == body['model']) &&
                m['npm'] == body['npm'] &&
                _allowedURL(m['url'], body['url']),
          )
          .firstOrNull;
      if (model == null ||
          body['method'] != 'POST' ||
          body['headers'] is! Map ||
          body['body'] is! String ||
          body['session'] is! String ||
          (body['session'] as String).length > 1024 ||
          !_allowedURL(model['url'], body['url'])) {
        throw const FormatException('Invalid native request');
      }
      // Validate the opaque body, but leave its protocol and model untouched.
      base64Decode(body['body']);
      final headers = <String, String>{};
      for (final entry in (body['headers'] as Map).entries) {
        if (entry.key is! String || entry.value is! String)
          throw const FormatException('Invalid headers');
        final name = (entry.key as String).toLowerCase();
        if (!{
              'authorization',
              'x-api-key',
              'x-goog-api-key',
              'host',
              'connection',
              'content-length',
              'transfer-encoding',
            }.contains(name) &&
            !name.startsWith('x-loongpass-'))
          headers[name] = entry.value;
      }
      if (!_current(grant)) {
        await _json(request.response, 401, {'error': 'grant_unavailable'});
        return;
      }
      try {
        await accounts.verifyCredential(account.key);
      } catch (_) {
        await _json(request.response, 401, {'error': 'grant_unavailable'});
        return;
      }
      if (!_current(grant)) {
        await _json(request.response, 401, {'error': 'grant_unavailable'});
        return;
      }
      final concurrency = limits['maxConcurrency'] as int? ?? 0;
      final atOnce = limits['maxAccounts'] as int? ?? 0;
      final busy = _active.values
          .where((g) => g.account.key == account.key)
          .length;
      final activeAccounts = {
        for (final g in _active.values)
          if (g.account.provider == account.provider) g.account.key,
      };
      if ((concurrency > 0 && busy >= concurrency) ||
          (atOnce > 0 &&
              !activeAccounts.contains(account.key) &&
              activeAccounts.length >= atOnce) ||
          _active.length >= 128) {
        request.response.headers.set('retry-after', '1');
        await _json(request.response, 429, {'error': 'account_busy'});
        return;
      }
      fetch = accounts.runtime.fetch({
        'provider': account.provider,
        'account': account.key,
        'model': model['apiId'],
        'npm': model['npm'],
        'url': body['url'],
        'method': 'POST',
        'headers': headers,
        'body': body['body'],
        'session': body['session'],
      });
      _active[fetch] = grant;
      final pending = fetch;
      unawaited(
        request.response.done.then(
          (_) => pending.cancel(),
          onError: (_) => pending.cancel(),
        ),
      );
      final reply = await fetch.response;
      request.response.statusCode = reply.status;
      reply.headers.forEach(request.response.headers.set);
      headed = true;
      await request.response.addStream(reply.body);
      await request.response.close();
    } on FormatException {
      if (!headed)
        await _json(request.response, 400, {'error': 'invalid_native_request'});
    } catch (_) {
      if (!headed) {
        try {
          await _json(request.response, 502, {
            'error': 'native_runtime_unavailable',
          });
        } catch (_) {}
      } else {
        try {
          await request.response.close();
        } catch (_) {}
      }
    } finally {
      if (fetch != null) {
        _active.remove(fetch);
        await fetch.cancel();
      }
    }
  }

  static Iterable<Map<String, dynamic>> _supportedModels(
    PluginAccount account,
  ) => account.models.where((model) {
    // Native Magpie video polling omits the selected model/SDK context.
    // Keep unsupported jobs out of both discovery and request admission.
    final outputs = model['outputs'];
    return outputs is! List || !outputs.contains('video');
  });

  static bool _allowedURL(Object? baseValue, Object? targetValue) {
    if (baseValue is! String || targetValue is! String) return false;
    final base = Uri.tryParse(baseValue), target = Uri.tryParse(targetValue);
    if (base == null ||
        target == null ||
        !{'https', 'http'}.contains(base.scheme) ||
        target.userInfo.isNotEmpty ||
        target.fragment.isNotEmpty ||
        target.scheme != base.scheme ||
        target.host != base.host ||
        target.port != base.port)
      return false;
    if (target.pathSegments.any(
      (s) => s == '..' || s == '.' || s.contains('/'),
    ))
      return false;
    final prefix = base.path.replaceAll(RegExp(r'/+$'), '');
    return target.path == prefix || target.path.startsWith('$prefix/');
  }

  Future<void> _stop() async {
    final server = _server;
    _server = null;
    for (final fetch in _active.keys.toList()) {
      await fetch.cancel();
    }
    await server?.close(force: true);
  }

  Future<void> close() async {
    _closed = true;
    accounts.removeListener(_changed);
    await _stop();
    await _writes;
    super.dispose();
  }
}
