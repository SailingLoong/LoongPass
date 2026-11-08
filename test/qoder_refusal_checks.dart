import 'dart:async';
import 'dart:convert';
import '../lib/model_provider.dart';
import '../lib/qoder_device_accounts.dart';
import '../lib/qoder_model_provider.dart';
import 'qoder_cn_checks.dart' show Native, RefreshTransport;
import 'qoder_alignment_checks.dart' show CatalogWire, chat, check;
import 'qoder_model_provider_checks.dart' show frame;

class Store extends Native {
  bool failRejection = false, loseRejectionAck = false;
  bool failPending = false, loseRotationAck = false;
  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> args,
  ) async {
    if (method == 'compareAndSet') {
      final row =
          (jsonDecode(args['payload'])['accounts'] as Map).values.single;
      if (failRejection &&
              row['accessRejected'] == true &&
              row['refreshPending'] != true ||
          failPending && row['refreshPending'] == true)
        throw StateError('synthetic unavailable store');
      final result = await super.call(method, args);
      if (loseRejectionAck &&
          row['accessRejected'] == true &&
          row['refreshPending'] != true) {
        loseRejectionAck = false;
        throw StateError('synthetic lost rejection acknowledgement');
      }
      if (loseRotationAck &&
          row['token'] == 'synthetic-new' &&
          row['refreshPending'] != true) {
        loseRotationAck = false;
        throw StateError('synthetic lost rotation acknowledgement');
      }
      return result;
    }
    return super.call(method, args);
  }

  Map<String, dynamic> get row => jsonDecode(payload)['accounts']['account-a'];
}

class Transport extends RefreshTransport {
  bool unknownRefresh = false;
  @override
  Future<QoderResponse> send(
    String method,
    Uri url,
    String? bearer,
    Map<String, dynamic>? body, {
    bool Function()? isCurrent,
  }) async {
    if (url.path.endsWith('/refresh') && unknownRefresh) {
      refreshes++;
      throw const QoderAccountError('network_error');
    }
    return super.send(method, url, bearer, body, isCurrent: isCurrent);
  }
}

class Rig {
  final native = Store(), http = Transport(), wire = CatalogWire();
  late QoderDeviceAccounts owner = roster();
  late QoderModelProvider provider = QoderModelProvider(owner, transport: wire);
  String registration = '';
  QoderDeviceAccounts roster() =>
      QoderDeviceAccounts(native: native, transport: http, nowMs: () => 100000);
  Future<void> login() async {
    await owner.startLogin();
    await owner.pollLogin();
    registration = (await provider.discoverModels('account-a')).registrationId;
  }

  void refuse([int code = 105]) {
    wire.answer = frame({
      'code': code,
      'message': 'synthetic vendor refusal',
    }, status: 403);
  }

  void accept() {
    wire.answer = null;
  }

  Future<void> send() => provider.dispatch(
    'account-a',
    registration,
    ModelProtocol.chat,
    chat(),
    (reply) => reply.body.drain<void>(),
    isCurrent: () => true,
    cancelled: Completer<void>().future,
  );
  Future<void> restart() async {
    owner.dispose();
    owner = roster();
    provider = QoderModelProvider(owner, transport: wire);
    await provider.discoverModels('account-a');
  }
}

Future<void> main() async {
  var failures = 0;
  Future<void> test(String name, Future<void> Function(Rig) run) async {
    final r = Rig();
    try {
      await r.login();
      await run(r);
      print('PASS $name');
    } catch (error) {
      failures++;
      print('FAIL $name: $error');
    } finally {
      r.owner.dispose();
    }
  }

  await test(
    'code105 persists exact grant refusal without replay and renews on next request',
    (r) async {
      r.refuse();
      await r.send();
      check(
        r.native.row['accessRejected'] == true &&
            r.wire.sent.length == 1 &&
            r.http.refreshes == 0,
        'definite token refusal was forgotten or inference replayed',
      );
      final registration = r.registration;
      r.accept();
      await r.restart();
      await r.send();
      check(
        r.http.refreshes == 1 &&
            r.wire.sent.length == 2 &&
            r.native.row['token'] == 'synthetic-new' &&
            r.native.row['registrationId'] == registration,
        'new operation did not preserve grant identity through one renewal',
      );
    },
  );
  await test('ordinary403 is not a token refusal', (r) async {
    r.refuse(406);
    await r.send();
    r.accept();
    await r.send();
    check(
      r.http.refreshes == 0 && r.native.row['accessRejected'] != true,
      'request rejection spent a refresh grant',
    );
  });
  await test('a rejected token with no refresh material requires login', (
    r,
  ) async {
    final data = jsonDecode(r.native.payload);
    data['accounts']['account-a']['refreshToken'] = '';
    r.native.payload = jsonEncode(data);
    r.refuse();
    await r.send();
    r.accept();
    var blocked = false;
    try {
      await r.send();
    } catch (_) {
      blocked = true;
    }
    check(
      blocked &&
          r.native.row['authorizationInvalid'] == true &&
          r.http.refreshes == 0 &&
          r.wire.sent.length == 1,
      'rejected nonrenewable grant was reused',
    );
  });
  await test(
    'a refused replacement requires login rather than endless refresh',
    (r) async {
      r.refuse();
      await r.send();
      r.accept();
      await r.send();
      r.refuse();
      await r.send();
      final before = r.wire.sent.length;
      var blocked = false;
      try {
        await r.send();
      } catch (_) {
        blocked = true;
      }
      check(
        blocked && r.http.refreshes == 1 && r.wire.sent.length == before,
        'replacement refusal repeated refresh or model POST',
      );
    },
  );
  await test('unknown refresh stays durably pending across restart', (r) async {
    r.refuse();
    await r.send();
    r.accept();
    r.http.unknownRefresh = true;
    try {
      await r.send();
    } catch (_) {}
    check(
      r.http.refreshes == 1 &&
          r.native.row['refreshPending'] == true &&
          r.wire.sent.length == 1,
      'unknown refresh could send inference or lost its durable reservation',
    );
    try {
      await r.restart();
      await r.send();
    } catch (_) {}
    check(
      r.http.refreshes == 1 && r.wire.sent.length == 1,
      'restart repeated unknown refresh',
    );
  });
  await test('failed reservation prevents refresh POST', (r) async {
    r.refuse();
    await r.send();
    r.accept();
    r.native.failPending = true;
    try {
      await r.send();
    } catch (_) {}
    check(
      r.http.refreshes == 0 && r.wire.sent.length == 1,
      'refresh dispatched before durable reservation',
    );
  });
  await test(
    'committed lost acknowledgements recover from the same account store',
    (r) async {
      r.native.loseRejectionAck = true;
      r.refuse();
      await r.send();
      r.accept();
      r.native.loseRotationAck = true;
      try {
        await r.send();
      } catch (_) {}
      await r.restart();
      await r.send();
      check(
        r.http.refreshes == 1 && r.native.row['token'] == 'synthetic-new',
        'lost save acknowledgement refreshed the old grant again',
      );
    },
  );
  await test(
    'late refusal is conditional on the dispatched token and registration',
    (r) async {
      final gate = Completer<void>();
      r.wire.replyWait = gate;
      r.refuse();
      final sending = r.send();
      while (r.wire.sent.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      final data = jsonDecode(r.native.payload);
      data['accounts']['account-a']['token'] = 'synthetic-new';
      data['accounts']['account-a']['generation'] =
          '33333333-3333-4333-8333-333333333333';
      await r.native.call('compareAndSet', {
        'expectedRevision': r.native.revision,
        'payload': jsonEncode(data),
      });
      gate.complete();
      await sending;
      r.wire.replyWait = null;
      r.accept();
      await r.send();
      check(
        r.http.refreshes == 0 && r.native.row['accessRejected'] != true,
        'old response poisoned a newer stored token',
      );
    },
  );
  await test('failed refusal persistence fails closed in the current process', (
    r,
  ) async {
    r.native.failRejection = true;
    r.refuse();
    try {
      await r.send();
    } catch (_) {}
    r.accept();
    var blocked = false;
    try {
      await r.send();
    } catch (_) {
      blocked = true;
    }
    check(
      blocked && r.wire.sent.length == 1 && r.http.refreshes == 0,
      'unsaved refusal let the rejected token send again',
    );
  });
  if (failures > 0) throw StateError('$failures Qoder refusal regressions');
}
