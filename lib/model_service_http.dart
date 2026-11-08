part of 'model_service.dart';

extension _ModelServiceHttp on ModelService {
  ModelRequestContext _clientContext(
    HttpRequest request,
    Map<String, dynamic> body,
    String key,
  ) {
    final session = request.headers.value('x-loongpass-session');
    if (session != null &&
        (session.length > 512 ||
            session.runes.any((r) => r < 32 || r == 127))) {
      throw const ModelServiceFailure('invalid_session');
    }
    return ModelRequestContext.fromRequest(
      body,
      session: session,
      scope: key,
      anthropicBeta: request.headers.value('anthropic-beta'),
    );
  }

  Future<void> _handlePooled(HttpRequest request, String key) async {
    final response = request.response;
    var committed = false, dispatched = false;
    ModelTarget? target;
    Completer<void>? signal;
    try {
      if (request.method == 'GET' && request.uri.path == '/v1/models') {
        response.headers.contentType = ContentType.json;
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        response.write(
          jsonEncode({
            'object': 'list',
            'data': [for (final model in pooledModels) model.toJson()],
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
      final Object? parsed;
      try {
        parsed = jsonDecode(utf8.decode(bytes));
      } catch (_) {
        await _error(response, 400, 'invalid_request');
        return;
      }
      if (parsed is! Map<String, dynamic> ||
          parsed['model'] is! String ||
          parsed['messages'] is! List ||
          parsed['stream'] != null && parsed['stream'] is! bool) {
        await _error(response, 400, 'invalid_request');
        return;
      }
      final body = parsed;
      final model = pooledModels
          .where((m) => m.id == body['model'])
          .firstOrNull;
      if (model == null) {
        await _error(response, 404, 'model_not_available');
        return;
      }
      final requestContext = _clientContext(request, body, key);
      final wires = <String, Map<String, dynamic>>{};
      final ready = <ModelTarget>[];
      ModelServiceFailure? unsupported;
      final snapshots = <String, List<ModelAccount>>{};
      for (final candidate in model.targets) {
        final row = _rows[candidate.bindingId];
        final source = _providers[candidate.providerId];
        if (row == null || source == null) continue;
        if (body['tools'] is List &&
            (body['tools'] as List).isNotEmpty &&
            candidate.model.tools == false)
          continue;
        if (!snapshots.containsKey(source.id)) {
          try {
            snapshots[source.id] = await source.accounts();
          } catch (_) {
            snapshots[source.id] = [];
          }
        }
        if (!snapshots[source.id]!.any(
          (a) =>
              a.id == row['accountId'] &&
              a.registrationId == row['registrationId'],
        ))
          continue;
        try {
          final wire = candidate.model.protocol == ModelProtocol.chat
              ? messagesToChat(body, candidate.model.id)
              : {...body, 'model': candidate.model.id};
          candidate.model.validateInput(wire);
          source.validateRequest(candidate.model.protocol, wire);
          wires[candidate.id] = wire;
          ready.add(candidate);
        } on ModelServiceFailure catch (e) {
          unsupported = e;
        }
      }
      if (ready.isEmpty) {
        await _error(
          response,
          unsupported == null ? 503 : 400,
          unsupported?.code ?? 'model_temporarily_unavailable',
        );
        return;
      }
      target = _router.select(
        model.id,
        ready,
        session: requestContext.hasSession ? requestContext.sessionId : null,
      );
      final selected = target;
      final row = Map<String, dynamic>.from(_rows[selected.bindingId]);
      final provider = _providers[selected.providerId]!;
      final registration = row['registrationId'] as String;
      final cancellation = signal = Completer<void>();
      _active[cancellation] = selected.bindingId;
      _pooledActive.add(cancellation);
      void cancel() {
        if (!cancellation.isCompleted) cancellation.complete();
      }

      unawaited(
        response.done.then<void>(
          (_) => cancel(),
          onError: (Object _) => cancel(),
        ),
      );
      bool current() {
        final now = _rows[selected.bindingId];
        return !_closed &&
            !cancellation.isCompleted &&
            pooledKey == key &&
            now?['enabled'] == true &&
            now?['registrationId'] == registration &&
            now?['accountId'] == row['accountId'] &&
            identical(_providers[selected.providerId], provider);
      }

      if (!current()) throw const ModelServiceFailure('account_unavailable');
      dispatched = true;
      await provider.dispatch(
        row['accountId'],
        registration,
        selected.model.protocol,
        wires[selected.id]!,
        (reply) async {
          lastStatus = reply.status;
          _notify();
          unawaited(cancellation.future.then((_) => reply.cancel?.call()));
          if (!current())
            throw const ModelServiceFailure('account_unavailable');
          if (reply.status < 200 || reply.status >= 300) {
            if ({401, 403, 404, 408, 409, 429}.contains(reply.status) ||
                reply.status >= 500)
              _router.failed(
                selected,
                retryAfterSeconds: reply.retryAfterSeconds,
              );
            await _error(
              response,
              reply.status >= 400 && reply.status <= 599 ? reply.status : 502,
              reply.errorCode ?? 'upstream_rejected',
              retryAfterSeconds: reply.retryAfterSeconds,
            );
            return;
          }
          final normalized = selected.model.protocol == ModelProtocol.chat
              ? await messagesChatReply(
                  reply,
                  modelId: model.id,
                  stream: body['stream'] == true,
                )
              : await messagesNativeReply(
                  reply,
                  modelId: model.id,
                  stream: body['stream'] == true,
                );
          response.statusCode = normalized.status;
          response.headers.set(
            HttpHeaders.contentTypeHeader,
            normalized.contentType,
          );
          response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
          response.headers.set('x-should-retry', 'false');
          response.headers.set('x-loongpass-platform', selected.providerId);
          response.bufferOutput = false;
          committed = true;
          await response.addStream(
            normalized.body.map((part) {
              if (!current())
                throw const ModelServiceFailure('account_unavailable');
              return part;
            }),
          );
          await response.close();
        },
        isCurrent: current,
        cancelled: cancellation.future,
        context: requestContext.forAccount(
          '${selected.providerId}/${row['accountId']}/$registration',
        ),
      );
    } catch (failure) {
      if (dispatched && target != null && signal?.isCompleted != true)
        _router.failed(target);
      lastStatus = 502;
      _notify();
      try {
        if (committed) {
          final socket = await response.detachSocket(writeHeaders: false);
          socket.destroy();
        } else {
          final code = failure is ModelServiceFailure
              ? failure.code
              : 'request_incomplete';
          await _error(
            response,
            code == 'invalid_session'
                ? 400
                : code == 'model_temporarily_unavailable'
                ? 503
                : 502,
            code,
          );
        }
      } catch (_) {}
    } finally {
      if (signal != null) {
        _active.remove(signal);
        _pooledActive.remove(signal);
        if (!signal.isCompleted) signal.complete();
      }
    }
  }

  Future<void> _error(
    HttpResponse response,
    int status,
    String code, {
    int? retryAfterSeconds,
  }) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.headers.set('x-should-retry', 'false');
    if (retryAfterSeconds != null && retryAfterSeconds >= 0) {
      response.headers.set('retry-after', '$retryAfterSeconds');
    }
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
      if (key != null && key == pooledKey) {
        await _handlePooled(request, key);
        return;
      }
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
      final models = _modelsFor(
        row,
      ).where((m) => m.protocol == protocol).toList();
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
      final callPath = '/v1${protocol.endpoint}';
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
      final ModelRequestContext requestContext;
      try {
        models.firstWhere((m) => m.id == body['model']).validateInput(body);
        provider.validateRequest(protocol, body);
        requestContext = _clientContext(request, body, key);
      } on ModelServiceFailure catch (failure) {
        await _error(response, 400, failure.code);
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
              reply.errorCode ?? 'upstream_rejected',
              retryAfterSeconds: reply.retryAfterSeconds,
            );
            return;
          }
          response.statusCode = reply.status;
          response.headers.set(
            HttpHeaders.contentTypeHeader,
            reply.contentType,
          );
          response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
          response.headers.set('x-should-retry', 'false');
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
        context: requestContext.forAccount(
          '$providerId/$accountId/$registration',
        ),
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
