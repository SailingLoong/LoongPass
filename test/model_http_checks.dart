import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../lib/model_http.dart';
import '../lib/model_provider.dart';

void check(bool ok, String why) {
  if (!ok) throw StateError(why);
}

Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var calls = 0;
  final accepted = Completer<void>();
  server.listen((r) async {
    calls++;
    final body = await utf8.decoder.bind(r).join();
    switch (r.uri.path) {
      case '/utf8':
        check(
          jsonDecode(body)['text'] == '中文 — native prompt',
          'JSON body was not UTF-8',
        );
        r.response.statusCode = 204;
        await r.response.close();
      case '/redirect':
        r.response.statusCode = 307;
        r.response.headers.set('location', '/target');
        await r.response.close();
      case '/json':
        r.response.write('{"data":[{"id":"real"}]}');
        await r.response.close();
      case '/large':
        r.response.write('x' * 100);
        await r.response.close();
      case '/hold':
        if (!accepted.isCompleted) accepted.complete();
      case '/rejected-token':
      case '/bare-unauthorized':
      case '/forbidden-token':
      case '/other-auth-error':
        r.response.statusCode = r.uri.path == '/forbidden-token' ? 403 : 401;
        if (r.uri.path != '/bare-unauthorized')
          r.response.headers.set(
            'www-authenticate',
            'Bearer error="${r.uri.path == '/other-auth-error' ? 'insufficient_scope' : 'invalid_token'}"',
          );
        await r.response.close();
      default:
        r.response.statusCode = 502;
        r.response.headers.set('retry-after', '37');
        await r.response.close();
    }
  });
  final transport = ModelHttp();
  final root = Uri.parse('http://127.0.0.1:${server.port}');
  try {
    await transport.exchange(
      root.resolve('/utf8'),
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: {'text': '中文 — native prompt'},
      isCurrent: () => true,
      consume: (r) async {
        check(r.status == 204, 'UTF-8 request failed');
        await r.body.drain<void>();
      },
    );
    final obj = await modelJson(
      transport,
      root.resolve('/json'),
      isCurrent: () => true,
    );
    check(obj['data'][0]['id'] == 'real', 'JSON decode');
    final before = calls;
    var status = 0;
    await transport.exchange(
      root.resolve('/redirect'),
      headers: {'Authorization': 'Bearer synthetic'},
      isCurrent: () => true,
      consume: (r) async {
        status = r.status;
        await r.body.drain<void>();
      },
    );
    check(
      status == 307 && calls == before + 1,
      'redirect leaked credentials or resent',
    );
    try {
      await modelJson(
        transport,
        root.resolve('/large'),
        isCurrent: () => true,
        maxBytes: 10,
      );
      throw StateError('unbounded');
    } on ModelServiceFailure catch (e) {
      check(e.code == 'invalid_model_catalog', 'large response');
    }
    final cancel = Completer<void>();
    final held = transport.exchange(
      root.resolve('/hold'),
      isCurrent: () => !cancel.isCompleted,
      cancelled: cancel.future,
      consume: (r) async {
        await r.body.drain<void>();
      },
    );
    await accepted.future;
    cancel.complete();
    var failed = false;
    try {
      await held.timeout(const Duration(seconds: 2));
    } catch (_) {
      failed = true;
    }
    check(failed, 'cancel before headers did not abort');
    final count = calls;
    for (final path in [
      '/rejected-token',
      '/bare-unauthorized',
      '/forbidden-token',
      '/other-auth-error',
    ]) {
      await transport.exchange(
        root.resolve(path),
        isCurrent: () => true,
        consume: (r) async {
          check(
            r.credentialRejected == (path == '/rejected-token'),
            'credential refusal evidence was invented or dropped',
          );
          await r.body.drain<void>();
        },
      );
    }
    check(calls == count + 4, 'credential failure was retried');
    final errorCount = calls;
    await transport.exchange(
      root.resolve('/error'),
      isCurrent: () => true,
      consume: (r) async {
        check(r.status == 502, 'status lost');
        check(r.retryAfterSeconds == 37, 'upstream retry timing lost');
        await r.body.drain<void>();
      },
    );
    check(calls == errorCount + 1, 'transport retried');
    print(
      'PASS model HTTP single-send, redirect, bounds and cancellation before headers',
    );
  } finally {
    await server.close(force: true);
  }
}
