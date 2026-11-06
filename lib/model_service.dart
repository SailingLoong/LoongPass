import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'account_document_store.dart';

class ModelAccount {
  final String id, label;
  const ModelAccount(this.id, this.label);
}

class ModelReply {
  final int status;
  final String contentType;
  final Stream<List<int>> body;
  final void Function()? cancel;
  const ModelReply(this.status, this.contentType, this.body, {this.cancel});
}

/// Providers retain their account's authorization owner until consumption ends.
abstract interface class ModelProvider {
  String get id;
  String get name;
  Future<List<ModelAccount>> accounts();
  Future<void> dispatch(
    String accountId,
    Map<String, dynamic> body,
    Future<void> Function(ModelReply) consume,
  );
}

class ModelServiceFailure implements Exception {
  final String code;
  const ModelServiceFailure(this.code);
  @override
  String toString() => 'ModelServiceFailure($code)';
}

/// Owns connection intent and the listener. Views read state or issue explicit
/// commands. Provider credentials and refresh remain with the platform owner.
class ModelService {
  final AccountDocumentStore store;
  final int port;
  final _providers = <String, ModelProvider>{};
  Map<String, dynamic>? _settings;
  HttpServer? _server;
  bool _busy = false, _closed = false;
  String? error;
  int? lastStatus;
  void Function()? onChanged;
  ModelService({required this.store, this.port = 3426});

  bool get running => _server != null;
  bool get busy => _busy;
  String? get providerId => _settings?['providerId'];
  String? get accountId => _settings?['accountId'];
  String? get model => _settings?['model'];
  String? get callerKey => _settings?['key'];
  Iterable<ModelProvider> get providers => _providers.values;
  Uri? get endpoint => _server == null
      ? null
      : Uri(scheme: 'http', host: '127.0.0.1', port: _server!.port);
  Uri? get importUri => !running
      ? null
      : Uri(
          scheme: 'magpie',
          host: 'import',
          queryParameters: {
            'name': 'LoongPass',
            'anthropic': endpoint.toString(),
            'key': callerKey!,
            'models': model!,
          },
        );

  void register(ModelProvider provider) {
    if (_closed) return;
    _providers[provider.id] = provider;
    _notify();
  }

  void _notify() {
    if (!_closed) onChanged?.call();
  }

  Future<void> _command(Future<void> Function() action) async {
    if (_closed || _busy) throw const ModelServiceFailure('busy');
    _busy = true;
    error = null;
    _notify();
    try {
      await action();
    } catch (failure) {
      error = failure is ModelServiceFailure
          ? failure.code
          : 'connection_unavailable';
      rethrow;
    } finally {
      _busy = false;
      _notify();
    }
  }

  static bool _text(dynamic value) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= 256 &&
      value.trim() == value &&
      !value.runes.any((c) => c < 32 || c == 127);

  Future<void> load() => _command(() async {
    final doc = await store.read();
    if (doc.data.isEmpty) return;
    final value = doc.data;
    if (value['version'] != 1 ||
        value['enabled'] is! bool ||
        !['providerId', 'accountId', 'model'].every((k) => _text(value[k])) ||
        value['key'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value['key'])) {
      throw const ModelServiceFailure('invalid_settings');
    }
    _settings = value;
    if (value['enabled']) await _listen();
  });

  Future<void> _save(Map<String, dynamic> value) async {
    try {
      final current = await store.read();
      await store.write(current.revision, value);
      _settings = value;
    } catch (_) {
      throw const ModelServiceFailure('save_failed');
    }
  }

  Future<void> configure({
    required String providerId,
    required String accountId,
    required String model,
  }) => _command(() async {
    if (running) throw const ModelServiceFailure('stop_before_configuring');
    final provider = _providers[providerId];
    if (provider == null ||
        ![providerId, accountId, model].every(_text) ||
        !(await provider.accounts()).any((a) => a.id == accountId)) {
      throw const ModelServiceFailure('account_required');
    }
    final random = Random.secure();
    await _save({
      'version': 1,
      'enabled': false,
      'providerId': providerId,
      'accountId': accountId,
      'model': model,
      'key':
          callerKey ??
          base64Url
              .encode(List.generate(32, (_) => random.nextInt(256)))
              .replaceAll('=', ''),
    });
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
        (request) => unawaited(_handle(request)),
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
    if (_settings == null) throw const ModelServiceFailure('account_required');
    await _listen();
    try {
      await _save({..._settings!, 'enabled': true});
    } catch (_) {
      await _closeListener();
      rethrow;
    }
  });

  Future<void> stop() => _command(() async {
    await _closeListener();
    if (_settings != null) await _save({..._settings!, 'enabled': false});
  });

  Future<void> _closeListener() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> dispose() async {
    _closed = true;
    onChanged = null;
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
    try {
      if (request.headers.value('origin') != null) {
        await _error(response, 403, 'browser_origin_denied');
        return;
      }
      if (request.headers.value(HttpHeaders.authorizationHeader) !=
              'Bearer $callerKey' &&
          request.headers.value('x-api-key') != callerKey) {
        await _error(response, 401, 'authentication_required');
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/v1/models') {
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({
            'object': 'list',
            'data': [
              {'id': model, 'object': 'model', 'owned_by': 'loongpass'},
            ],
          }),
        );
        await response.close();
        return;
      }
      if (request.method != 'POST' || request.uri.path != '/v1/messages') {
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
      if (body['model'] != model) {
        await _error(response, 404, 'model_not_configured');
        return;
      }
      final provider = _providers[providerId];
      if (provider == null) {
        await _error(response, 503, 'account_owner_unavailable');
        return;
      }
      await provider.dispatch(accountId!, body, (reply) async {
        lastStatus = reply.status;
        _notify();
        if (reply.status < 200 || reply.status >= 300) {
          await _error(
            response,
            reply.status >= 400 && reply.status <= 599 ? reply.status : 502,
            'upstream_rejected',
          );
          return;
        }
        response.statusCode = reply.status;
        response.headers.set(HttpHeaders.contentTypeHeader, reply.contentType);
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        response.bufferOutput = false;
        // A disconnected client cancels the official request, never replays it.
        unawaited(
          response.done.then<void>(
            (_) => reply.cancel?.call(),
            onError: (Object _) => reply.cancel?.call(),
          ),
        );
        committed = true;
        await response.addStream(reply.body);
        await response.close();
      });
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
    }
  }
}
