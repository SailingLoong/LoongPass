import 'dart:async';
import 'dart:convert';
import '../lib/workbuddy_vault.dart';
import 'workbuddy_alignment_checks.dart' show Rig, chat, check;

Future<void> main() async {
  var failures = 0;
  Future<void> test(String name, Future<void> Function(Rig) run) async {
    final rig = Rig();
    try {
      await rig.login();
      await run(rig);
      print('PASS $name');
    } catch (error) {
      failures++;
      print('FAIL $name: $error');
    } finally {
      rig.close();
    }
  }

  void refuse(Rig r, [bool definite = true]) {
    r.wire.status = 401;
    r.wire.rejected = {'error': 'synthetic rejected'};
    r.wire.credentialRejected = definite;
  }

  void accept(Rig r) {
    r.wire.status = 200;
    r.wire.rejected = null;
    r.wire.credentialRejected = false;
  }

  await test(
    'early exact token refusal is durable and only the next request renews',
    (r) async {
      final registration = r.owner.accounts.single.registrationId;
      refuse(r);
      await r.send(chat());
      check(
        r.wire.calls.length == 1 &&
            r.server.renewals == 0 &&
            r.store.rows.values.single['accessRejected'] == true,
        'refused request replayed or owner did not save rejection',
      );
      r.owner.close();
      r.owner = r.roster();
      check(
        await r.owner.restoreSaved(
              r.vault,
              () async => r.store.rows.keys.toList(),
            ) ==
            1,
        'saved refusal did not recover through owner on restart',
      );
      accept(r);
      await r.send(chat());
      check(
        r.server.renewals == 1 &&
            r.wire.calls.length == 2 &&
            r.wire.calls.last.headers['Authorization'] ==
                'Bearer synthetic-renewed' &&
            r.owner.accounts.single.registrationId == registration &&
            r.store.rows.length == 1,
        'early renewal changed grant identity or repeated inference',
      );
    },
  );
  await test('bare path401 never invalidates a valid grant', (r) async {
    refuse(r, false);
    await r.send(chat());
    accept(r);
    await r.send(chat());
    check(
      r.server.renewals == 0 &&
          r.store.rows.values.single['accessRejected'] != true &&
          r.wire.calls.last.headers['Authorization'] !=
              'Bearer synthetic-renewed',
      'bare path401 was treated as token refusal',
    );
  });
  for (final oversized in [false, true]) {
    await test(
      'exact token refusal survives unreadable error body (oversized=$oversized)',
      (r) async {
        refuse(r);
        r.wire.replyBody = () async* {
          yield utf8.encode(
            oversized ? 'x' * (2 * 1024 * 1024 + 1) : '{"error":',
          );
          throw StateError('synthetic response reset');
        };
        try {
          await r.send(chat());
        } catch (_) {}
        check(
          r.store.rows.values.single['accessRejected'] == true &&
              r.wire.calls.length == 1 &&
              r.server.renewals == 0,
          'authoritative header refusal was lost with the response body',
        );
        r.wire.replyBody = null;
        accept(r);
        await r.send(chat());
        check(
          r.server.renewals == 1 &&
              r.wire.calls.length == 2 &&
              r.wire.calls.last.headers['Authorization'] ==
                  'Bearer synthetic-renewed',
          'next request reused the definitively rejected token',
        );
      },
    );
  }
  await test('a refused token-only saved grant requires login', (r) async {
    r.store.rows.values.single.remove('refreshToken');
    refuse(r);
    await r.send(chat());
    accept(r);
    var blocked = false;
    try {
      await r.send(chat());
    } catch (_) {
      blocked = true;
    }
    check(
      blocked && r.server.renewals == 0 && r.wire.calls.length == 1,
      'rejected token-only grant could still send',
    );
  });
  await test('a refused replacement cannot trigger an infinite refresh loop', (
    r,
  ) async {
    refuse(r);
    await r.send(chat());
    accept(r);
    await r.send(chat());
    refuse(r);
    await r.send(chat());
    final before = r.wire.calls.length;
    var blocked = false;
    try {
      await r.send(chat());
    } catch (_) {
      blocked = true;
    }
    check(
      blocked && r.server.renewals == 1 && r.wire.calls.length == before,
      'refused replacement spent another refresh grant',
    );
  });
  await test(
    'lost rejection acknowledgement reconciles the committed same row',
    (r) async {
      r.store.loseRejectionAck = true;
      refuse(r);
      await r.send(chat());
      accept(r);
      await r.send(chat());
      check(
        r.server.renewals == 1 &&
            r.store.rows.values.single['accessToken'] == 'synthetic-renewed',
        'lost acknowledgement resurrected the rejected token',
      );
    },
  );
  await test(
    'committed rotation with a lost acknowledgement restores without refresh replay',
    (r) async {
      refuse(r);
      await r.send(chat());
      accept(r);
      r.store.loseRotationAck = true;
      try {
        await r.send(chat());
      } catch (_) {}
      check(
        r.server.renewals == 1 &&
            r.wire.calls.length == 1 &&
            r.store.rows.values.single['accessToken'] == 'synthetic-renewed',
        'fixture did not commit renewal before lost acknowledgement',
      );
      r.owner.close();
      r.owner = r.roster();
      check(
        await r.owner.restoreSaved(
              r.vault,
              () async => r.store.rows.keys.toList(),
            ) ==
            1,
        'known committed replacement did not restore',
      );
      await r.send(chat());
      check(
        r.server.renewals == 1 && r.wire.calls.length == 2,
        'restart repeated the consumed refresh',
      );
    },
  );
  await test('unknown refusal renewal remains pending across restart', (
    r,
  ) async {
    refuse(r);
    await r.send(chat());
    accept(r);
    r.server.unknownRenewal = true;
    try {
      await r.send(chat());
    } catch (_) {}
    check(
      r.server.renewals == 1 &&
          r.store.rows.values.single['state'] == 'rotationPending',
      'unknown refresh lost its durable reservation',
    );
    r.owner.close();
    r.owner = r.roster();
    check(
      await r.owner.restoreSaved(
                r.vault,
                () async => r.store.rows.keys.toList(),
              ) ==
              0 &&
          r.server.renewals == 1 &&
          r.wire.calls.length == 1,
      'restart repeated the unknown refresh or inference',
    );
  });
  await test('failed refusal save blocks all new sends in the process', (
    r,
  ) async {
    r.store.failRejectionSave = true;
    refuse(r);
    try {
      await r.send(chat());
    } catch (_) {}
    accept(r);
    var blocked = false;
    try {
      await r.send(chat());
    } catch (_) {
      blocked = true;
    }
    check(
      blocked && r.wire.calls.length == 1 && r.server.renewals == 0,
      'storage failure let a rejected token send again',
    );
  });
  await test(
    'late old-token refusal cannot poison an already saved replacement',
    (r) async {
      final gate = Completer<void>();
      r.wire.replyWait = gate;
      refuse(r);
      final sending = r.send(chat());
      while (r.wire.calls.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      final key = r.store.rows.keys.single;
      final ticket = (await r.vault.beginRotation(key))!;
      check(
        await r.vault.completeRotation(
          ticket,
          WorkBuddyVaultCredential(
            domain: 'www.workbuddy.cn',
            endpoint: 'www.workbuddy.cn',
            uid: 'A',
            accessToken: 'synthetic-renewed',
            refreshToken: 'synthetic-next-refresh',
            expiresAt: r.now.add(const Duration(hours: 1)),
          ),
        ),
        'fixture rotation failed',
      );
      gate.complete();
      await sending;
      r.wire.replyWait = null;
      accept(r);
      r.owner.close();
      r.owner = r.roster();
      check(
        await r.owner.restoreSaved(r.vault, () async => [key]) == 1,
        'fresh replacement could not restore',
      );
      await r.send(chat());
      check(
        r.server.renewals == 0 &&
            r.store.rows.values.single['accessRejected'] != true,
        'old-token response changed the new saved token',
      );
    },
  );
  if (failures > 0) throw StateError('$failures WorkBuddy refusal regressions');
}
