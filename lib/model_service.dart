import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'account_document_store.dart';
import 'model_provider.dart';
export 'model_provider.dart';

/// Owns local caller grants, model snapshots and listener lifecycle. Platform
/// credentials, identity and refresh belong to the injected account owners.
class ModelService {
  final AccountDocumentStore store;
  final int port;
  final _providers = <String, ModelProvider>{};
  final _subscriptions = <String, StreamSubscription<void>>{};
  final _catalogs = <String, ModelCatalog>{};
  final _catalogErrors = <String, String>{};
  final _queriedAt = <String, DateTime>{};
  final _active = <Completer<void>, String>{};
  Map<String, dynamic> _settings = {
    'version': 2,
    'enabled': false,
    'bindings': <String, dynamic>{},
  };
  Future<void> _tail = Future.value();
  int _pending = 0;
  HttpServer? _server;
  bool _closed = false, _loaded = false;
  String? error;
  int? lastStatus;
  void Function()? onChanged;
  ModelService({required this.store, this.port = 3426});

  bool get running => _server != null;
  bool get busy => _pending > 0;
  Future<void> get settled => _tail;
  Iterable<ModelProvider> get providers => _providers.values;
  Map<String, dynamic> get _rows =>
      _settings['bindings'] as Map<String, dynamic>;
  Uri? get endpoint => _server == null
      ? null
      : Uri(scheme: 'http', host: '127.0.0.1', port: _server!.port);
  List<ModelBinding> get bindings => List.unmodifiable([
    for (final row in _rows.values)
      ModelBinding(
        id: row['id'],
        providerId: row['providerId'],
        accountId: row['accountId'],
        key: row['key'],
        registrationId: row['registrationId'],
        enabled: row['enabled'],
        models: _catalogs[row['id']]?.models ?? const [],
        error: _catalogErrors[row['id']],
        queriedAt: _queriedAt[row['id']],
      ),
  ]);

  Uri? importUriFor(String id) {
    final row = _rows[id];
    if (!running || row == null || row['enabled'] != true) return null;
    final providerId = row['providerId'] as String;
    final catalog = _catalogs[id];
    if (catalog == null || catalog.models.isEmpty) return null;
    final root = endpoint!;
    final protocols = catalog.models.map((m) => m.protocol).toSet();
    final source = _providers[providerId];
    return Uri(
      scheme: 'magpie',
      host: 'import',
      queryParameters: {
        'id': 'loongpass-$providerId',
        'name': 'LoongPass ' + (source?.name ?? providerId),
        'key': row['key'],
        'models': catalog.models.map((m) => m.id).join(','),
        if (protocols.contains(ModelProtocol.messages))
          'anthropic': root
              .resolve('/providers/$providerId/messages')
              .toString(),
        if (protocols.contains(ModelProtocol.chat))
          'chat': root.resolve('/providers/$providerId/chat/v1').toString(),
      },
    );
  }

  void register(ModelProvider provider) {
    if (_closed) return;
    if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$').hasMatch(provider.id)) {
      throw const ModelServiceFailure('invalid_provider');
    }
    final previous = _providers[provider.id];
    if (identical(previous, provider)) return;
    unawaited(_subscriptions.remove(provider.id)?.cancel());
    if (previous != null) {
      for (final row in _rows.values.where(
        (r) => r['providerId'] == provider.id,
      )) {
        _cancelFor(row['id']);
        _catalogs.remove(row['id']);
      }
    }
    _providers[provider.id] = provider;
    _subscriptions[provider.id] = provider.changes.listen(
      (_) => _scheduleRefresh(provider.id),
      onError: (Object _) => _scheduleRefresh(provider.id),
    );
    if (_loaded) _scheduleRefresh(provider.id);
    _notify();
  }

  void _scheduleRefresh(String providerId) {
    if (_closed || !_loaded) return;
    unawaited(
      _command(() async {
        final ids = _rows.values
            .where((r) => r['providerId'] == providerId)
            .map((r) => r['id'] as String)
            .toList();
        for (final id in ids) {
          if (_rows[id]?['enabled'] == true) await _refreshOne(id);
        }
      }).catchError((Object _) {}),
    );
  }

  void _notify() {
    if (_closed) return;
    try {
      onChanged?.call();
    } catch (_) {}
  }

  Future<T> _command<T>(Future<T> Function() action) {
    if (_closed) return Future.error(const ModelServiceFailure('closed'));
    _pending++;
    _notify();
    final next = _tail.then((_) async {
      try {
        if (_closed) throw const ModelServiceFailure('closed');
        error = null;
        return await action();
      } catch (failure) {
        error = failure is ModelServiceFailure
            ? failure.code
            : 'connection_unavailable';
        rethrow;
      } finally {
        _pending--;
        _notify();
      }
    });
    _tail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  static bool _text(Object? value) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= 256 &&
      value.trim() == value &&
      !value.runes.any((c) => c < 32 || c == 127);
  static bool _key(Object? value) =>
      value is String && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value);
  static String _random(int count) => base64Url
      .encode(List.generate(count, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');
  static Map<String, dynamic> _copy(Map<String, dynamic> value) =>
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

  static bool _equal(Object? a, Object? b) {
    if (a is Map && b is Map)
      return a.length == b.length &&
          a.keys.every((k) => b.containsKey(k) && _equal(a[k], b[k]));
    if (a is List && b is List)
      return a.length == b.length &&
          List.generate(a.length, (i) => _equal(a[i], b[i])).every((v) => v);
    return a == b;
  }

  static void _validate(Map<String, dynamic> value) {
    if (value['version'] != 2 ||
        value['enabled'] is! bool ||
        value['bindings'] is! Map<String, dynamic> ||
        value.keys.any(
          (k) => !{'version', 'enabled', 'bindings'}.contains(k),
        )) {
      throw const ModelServiceFailure('invalid_settings');
    }
    final keys = <String>{};
    for (final entry in (value['bindings'] as Map<String, dynamic>).entries) {
      final row = entry.value;
      if (row is! Map<String, dynamic> ||
          row['id'] != entry.key ||
          !['id', 'providerId', 'accountId'].every((k) => _text(row[k])) ||
          !_key(row['key']) ||
          !keys.add(row['key']) ||
          row['enabled'] is! bool ||
          row['registrationId'] != null && !_text(row['registrationId']) ||
          row['registrationId'] == null && row['legacy'] != true ||
          row['legacy'] != null && row['legacy'] is! bool ||
          row['legacyModel'] != null && !_text(row['legacyModel']) ||
          row.keys.any(
            (k) => !{
              'id',
              'providerId',
              'accountId',
              'registrationId',
              'key',
              'enabled',
              'legacy',
              'legacyModel',
            }.contains(k),
          )) {
        throw const ModelServiceFailure('invalid_settings');
      }
    }
  }

  Future<void> _save(Map<String, dynamic> value) async {
    if (_closed) throw const ModelServiceFailure('closed');
    _validate(value);
    try {
      final current = await store.read();
      await store.write(current.revision, value);
      _settings = _copy(value);
    } catch (_) {
      try {
        final saved = await store.read();
        if (_equal(saved.data, value)) {
          _settings = _copy(saved.data);
          return;
        }
      } catch (_) {}
      throw const ModelServiceFailure('save_failed');
    }
  }

  Future<void> load() => _command(() async {
    final saved = await store.read();
    var value = saved.data;
    if (value.isEmpty) {
      _loaded = true;
      return;
    }
    if (value['version'] == 1) {
      if (value['enabled'] is! bool ||
          !_key(value['key']) ||
          !['providerId', 'accountId', 'model'].every((k) => _text(value[k]))) {
        throw const ModelServiceFailure('invalid_settings');
      }
      final legacy = value;
      value = {
        'version': 2,
        'enabled': legacy['enabled'],
        'bindings': <String, dynamic>{
          'legacy': {
            'id': 'legacy',
            'providerId': legacy['providerId'],
            'accountId': legacy['accountId'],
            'registrationId': null,
            'key': legacy['key'],
            'enabled': true,
            'legacy': true,
            'legacyModel': legacy['model'],
          },
        },
      };
      await _save(value);
    } else {
      _validate(value);
      _settings = _copy(value);
    }
    _loaded = true;
    for (final id in _rows.keys.toList()) {
      if (_rows[id]['enabled'] == true) await _refreshOne(id);
    }
    if (_settings['enabled'] == true) await _listen();
  });

  ModelProvider _provider(String id) =>
      _providers[id] ??
      (throw const ModelServiceFailure('account_owner_unavailable'));

  ModelCatalog _checkedCatalog(ModelProvider provider, ModelCatalog catalog) {
    if (!_text(catalog.registrationId) || catalog.models.isEmpty) {
      throw const ModelServiceFailure('model_discovery_failed');
    }
    final ids = <String>{};
    for (final model in catalog.models) {
      if (!_text(model.id) ||
          model.id.contains(',') ||
          !_text(model.name) ||
          !ids.add(model.id) ||
          !provider.protocols.contains(model.protocol)) {
        throw const ModelServiceFailure('invalid_model_catalog');
      }
    }
    return catalog;
  }

  Future<ModelBinding> addAccount({
    required String providerId,
    required String accountId,
  }) => _command(() async {
    final provider = _provider(providerId);
    if (!(await provider.accounts()).any((a) => a.id == accountId)) {
      throw const ModelServiceFailure('account_required');
    }
    final catalog = _checkedCatalog(
      provider,
      await provider.discoverModels(accountId),
    );
    if (_closed) throw const ModelServiceFailure('closed');
    final rows = _copy(_settings)['bindings'] as Map<String, dynamic>;
    Map<String, dynamic>? existing;
    for (final row in rows.values) {
      if (row['providerId'] == providerId &&
          row['accountId'] == accountId &&
          row['registrationId'] == catalog.registrationId) {
        existing = row;
        break;
      }
    }
    final id = existing?['id'] as String? ?? _random(16);
    final removed = <String>[];
    rows.removeWhere((key, row) {
      final replace =
          key != id &&
          row['providerId'] == providerId &&
          row['accountId'] == accountId;
      if (replace) removed.add(key);
      return replace;
    });
    rows[id] = {
      'id': id,
      'providerId': providerId,
      'accountId': accountId,
      'registrationId': catalog.registrationId,
      'key': existing?['key'] ?? _random(32),
      'enabled': true,
      if (existing?['legacy'] == true) 'legacy': true,
      if (existing?['legacyModel'] != null)
        'legacyModel': existing!['legacyModel'],
    };
    await _save({..._settings, 'bindings': rows});
    for (final old in removed) {
      _cancelFor(old);
      _catalogs.remove(old);
      _catalogErrors.remove(old);
      _queriedAt.remove(old);
    }
    _catalogs[id] = catalog;
    _catalogErrors.remove(id);
    _queriedAt[id] = DateTime.now().toUtc();
    return bindings.firstWhere((v) => v.id == id);
  });

  Future<void> _refreshOne(String id) async {
    final row = _rows[id];
    if (row == null) return;
    try {
      final provider = _provider(row['providerId']);
      final catalog = _checkedCatalog(
        provider,
        await provider.discoverModels(row['accountId']),
      );
      if (row['registrationId'] != null &&
          row['registrationId'] != catalog.registrationId) {
        throw const ModelServiceFailure('account_changed');
      }
      if (row['registrationId'] == null) {
        final settings = _copy(_settings);
        settings['bindings'][id]['registrationId'] = catalog.registrationId;
        await _save(settings);
      }
      if (_closed) return;
      _catalogs[id] = catalog;
      _catalogErrors.remove(id);
      _queriedAt[id] = DateTime.now().toUtc();
    } catch (failure) {
      _catalogs.remove(id);
      _catalogErrors[id] = failure is ModelServiceFailure
          ? failure.code
          : 'model_discovery_failed';
    }
  }

  Future<void> refreshModels(String id) => _command(() => _refreshOne(id));

  Future<void> setEnabled(String id, bool enabled) => _command(() async {
    if (_rows[id] == null) throw const ModelServiceFailure('account_required');
    final settings = _copy(_settings);
    settings['bindings'][id]['enabled'] = enabled;
    await _save(settings);
    if (!enabled) _cancelFor(id);
    if (enabled) await _refreshOne(id);
  });

  Future<void> revoke(String id) => _command(() async {
    if (_rows[id] == null) return;
    final settings = _copy(_settings);
    (settings['bindings'] as Map).remove(id);
    await _save(settings);
    _cancelFor(id);
    _catalogs.remove(id);
    _catalogErrors.remove(id);
    _queriedAt.remove(id);
  });

  Future<void> _listen() async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      if (_closed) {
        await server.close(force: true);
        return;
      }
      server.idleTimeout = const Duration(seconds: 30);
      _server = server;
      server.listen(
        (r) => unawaited(_handle(r)),
        onError: (Object _) {
          error = 'listener_failed';
          unawaited(_closeListener());
          _notify();
        },
      );
    } catch (_) {
      throw const ModelServiceFailure('port_unavailable');
    }
  }

  Future<void> start() => _command(() async {
    if (running) return;
    if (_rows.isEmpty) throw const ModelServiceFailure('account_required');
    await _listen();
    try {
      await _save({..._settings, 'enabled': true});
    } catch (_) {
      await _closeListener();
      rethrow;
    }
  });

  Future<void> stop() => _command(() async {
    await _save({..._settings, 'enabled': false});
    await _closeListener();
  });

  void _cancelFor(String id) {
    for (final entry in _active.entries.toList()) {
      if (entry.value == id && !entry.key.isCompleted) entry.key.complete();
    }
  }

  Future<void> _closeListener() async {
    for (final signal in _active.keys.toList()) {
      if (!signal.isCompleted) signal.complete();
    }
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> dispose() async {
    _closed = true;
    onChanged = null;
    for (final subscription in _subscriptions.values) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _closeListener();
  }

  Future<void> _error(HttpResponse response, int status, String code) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.headers.set('x-should-retry', 'false');
    response.write(
      jsonEncode({
        'type': 'error',
        'error': {'type': code, 'message': code},
      }),
    );
    await response.close();
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    var committed = false;
    Completer<void>? cancellation;
    try {
      if (request.headers.value('origin') != null) {
        await _error(response, 403, 'browser_origin_denied');
        return;
      }
      final authorization = request.headers.value(
        HttpHeaders.authorizationHeader,
      );
      final bearer = authorization == null
          ? null
          : RegExp(
              r'^Bearer ([A-Za-z0-9_-]+)$',
              caseSensitive: false,
            ).firstMatch(authorization)?.group(1);
      final apiKey = request.headers.value('x-api-key');
      if (authorization != null && bearer == null ||
          bearer != null && apiKey != null && bearer != apiKey) {
        await _error(response, 401, 'authentication_required');
        return;
      }
      final key = bearer ?? apiKey;
      final matches = _rows.values.where(
        (r) => r['key'] == key && r['enabled'] == true,
      );
      if (key == null || matches.isEmpty) {
        await _error(response, 401, 'authentication_required');
        return;
      }
      final row = Map<String, dynamic>.from(matches.first);
      final id = row['id'] as String;
      final providerId = row['providerId'] as String;
      final segments = request.uri.pathSegments;
      ModelProtocol? protocol;
      String? relative;
      if (segments.length >= 4 && segments[0] == 'providers') {
        if (segments[1] != providerId) {
          await _error(response, 403, 'source_not_allowed');
          return;
        }
        for (final candidate in ModelProtocol.values) {
          if (candidate.name == segments[2]) protocol = candidate;
        }
        relative = '/' + segments.skip(3).join('/');
      } else if (row['legacy'] == true) {
        protocol = ModelProtocol.messages;
        relative = request.uri.path;
      }
      final provider = _providers[providerId];
      if (protocol == null ||
          relative == null ||
          provider != null && !provider.protocols.contains(protocol)) {
        await _error(response, 404, 'endpoint_not_supported');
        return;
      }
      if (provider == null) {
        await _error(response, 503, 'account_owner_unavailable');
        return;
      }
      final accountId = row['accountId'] as String;
      final registration = row['registrationId'] as String?;
      final accounts = await provider.accounts();
      if (registration == null ||
          !accounts.any(
            (a) => a.id == accountId && a.registrationId == registration,
          )) {
        await _error(response, 503, 'account_unavailable');
        return;
      }
      final catalog = _catalogs[id];
      if (catalog == null) {
        await _error(response, 503, 'model_catalog_unavailable');
        return;
      }
      final models = catalog.models
          .where(
            (m) =>
                m.protocol == protocol &&
                (row['legacyModel'] == null || m.id == row['legacyModel']),
          )
          .toList();
      if (request.method == 'GET' && relative == '/v1/models') {
        response.headers.contentType = ContentType.json;
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        response.write(
          jsonEncode({
            'object': 'list',
            'data': [for (final model in models) model.toJson(providerId)],
          }),
        );
        await response.close();
        return;
      }
      final callPath = protocol == ModelProtocol.messages
          ? '/v1/messages'
          : '/v1/chat/completions';
      if (request.method != 'POST' || relative != callPath) {
        await _error(response, 404, 'endpoint_not_supported');
        return;
      }
      final bytes = <int>[];
      await for (final part in request.timeout(const Duration(seconds: 15))) {
        if (bytes.length + part.length > 2 * 1024 * 1024) {
          response.persistentConnection = false;
          await _error(response, 413, 'request_too_large');
          return;
        }
        bytes.addAll(part);
      }
      final dynamic body;
      try {
        body = jsonDecode(utf8.decode(bytes));
      } catch (_) {
        await _error(response, 400, 'invalid_request');
        return;
      }
      if (body is! Map<String, dynamic> ||
          body['messages'] is! List ||
          body['stream'] != null && body['stream'] is! bool) {
        await _error(response, 400, 'invalid_request');
        return;
      }
      if (!models.any((m) => m.id == body['model'])) {
        await _error(response, 404, 'model_not_available');
        return;
      }
      final signal = cancellation = Completer<void>();
      _active[signal] = id;
      void cancel() {
        if (!signal.isCompleted) signal.complete();
      }

      unawaited(
        response.done.then<void>(
          (_) => cancel(),
          onError: (Object _) => cancel(),
        ),
      );
      bool current() {
        final now = _rows[id];
        return !_closed &&
            !signal.isCompleted &&
            now != null &&
            now['enabled'] == true &&
            now['key'] == key &&
            now['registrationId'] == registration &&
            identical(_providers[providerId], provider);
      }

      if (!current()) {
        await _error(response, 503, 'account_unavailable');
        return;
      }
      await provider.dispatch(
        accountId,
        registration,
        protocol,
        body,
        (reply) async {
          lastStatus = reply.status;
          _notify();
          unawaited(signal.future.then((_) => reply.cancel?.call()));
          if (!current())
            throw const ModelServiceFailure('account_unavailable');
          if (reply.status < 200 || reply.status >= 300) {
            await _error(
              response,
              reply.status >= 400 && reply.status <= 599 ? reply.status : 502,
              'upstream_rejected',
            );
            return;
          }
          response.statusCode = reply.status;
          response.headers.set(
            HttpHeaders.contentTypeHeader,
            reply.contentType,
          );
          response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
          response.bufferOutput = false;
          committed = true;
          await response.addStream(
            reply.body.map((chunk) {
              if (!current())
                throw const ModelServiceFailure('account_unavailable');
              return chunk;
            }),
          );
          await response.close();
        },
        isCurrent: current,
        cancelled: signal.future,
      );
    } catch (_) {
      lastStatus = 502;
      _notify();
      try {
        if (committed) {
          final socket = await response.detachSocket(writeHeaders: false);
          socket.destroy();
        } else {
          await _error(response, 502, 'request_incomplete');
        }
      } catch (_) {}
    } finally {
      if (cancellation != null) {
        _active.remove(cancellation);
        if (!cancellation.isCompleted) cancellation.complete();
      }
    }
  }
}
