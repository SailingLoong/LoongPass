import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../lib/model_service.dart';
import '../lib/model_http.dart';
import '../lib/workbuddy_accounts.dart';
import '../lib/workbuddy_account_flow.dart';
import '../lib/workbuddy_model_provider.dart';
import '../lib/workbuddy_vault.dart';
import '../tool/workbuddy_single_checks.dart' show Server, VaultStore;
import '../tool/workbuddy_multi_checks.dart' show Memory;
import 'memory_account_store.dart';
import 'workbuddy_model_provider_checks.dart' as fixture;

void check(bool ok, String why) {
  if (!ok) throw StateError(why);
}

class HeldTransport extends fixture.Wire {
  HeldTransport(this.root);
  final Uri root;
  @override
  Future<void> exchange(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const {},
    Object? body,
    required bool Function() isCurrent,
    Future<void>? cancelled,
    required Future<void> Function(ModelReply) consume,
  }) async {
    if (method == 'GET')
      return super.exchange(
        uri,
        method: method,
        headers: headers,
        body: body,
        isCurrent: isCurrent,
        cancelled: cancelled,
        consume: consume,
      );
    await ModelHttp().exchange(
      root.resolve('/held'),
      method: 'POST',
      headers: headers,
      body: body,
      isCurrent: isCurrent,
      cancelled: cancelled,
      consume: consume,
    );
  }
}

Future<void> run({required bool pooled, bool rotate = false}) async {
  final now = DateTime.utc(2026, 11, 7),
      server = Server('A'),
      saved = VaultStore();
  final vault = WorkBuddyVault(saved, now: () => now);
  final owner = WorkBuddyAccounts(
    create: () => WorkBuddyAccountFlow(
      exchange: server,
      store: Memory(),
      now: () => now,
      ownerGeneration: 'held',
      isOwnerCurrent: () => true,
    ),
  );
  final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var sends = 0;
  final entered = Completer<void>();
  upstream.listen((r) async {
    sends++;
    await r.drain<void>();
    if (!entered.isCompleted) entered.complete();
  });
  final source = WorkBuddyModelProvider(
    owner,
    clientVersion: () async => '6.0.1',
    transport: HeldTransport(Uri.parse('http://127.0.0.1:${upstream.port}')),
  );
  final service = ModelService(store: MemoryAccountStore('held-local'), port: 0)
    ..register(source);
  final client = HttpClient();
  try {
    final grant = (await owner.beginAuthorization())!;
    await owner.pollAndSave(grant.sessionId, vault);
    await service.load();
    final a = (await source.accounts()).single;
    final binding = await service.addAccount(
      providerId: source.id,
      accountId: a.id,
    );
    await service.start();
    await service.settled;
    final request = await client.postUrl(
      service.endpoint!.resolve(
        pooled
            ? '/v1/messages'
            : '/providers/workbuddy-cn/messages/v1/messages',
      ),
    );
    request.headers.set('x-api-key', pooled ? service.pooledKey! : binding.key);
    request.write(jsonEncode({'model': 'claude-live', 'messages': []}));
    final pending = request.close();
    await entered.future;
    if (rotate) {
      await service.rotatePooledKey();
    } else {
      await owner.revokeStored(owner.accounts.single.id);
    }
    var promptly = false;
    try {
      final response = await pending.timeout(const Duration(seconds: 2));
      await response.drain<void>();
      promptly = true;
    } catch (_) {}
    check(
      promptly && sends == 1,
      'owner removal left an upstream header wait active or resent',
    );
  } finally {
    await service.dispose();
    client.close(force: true);
    owner.close();
    vault.close();
    await upstream.close(force: true);
  }
}

Future<void> main() async {
  await run(pooled: false);
  await run(pooled: true);
  await run(pooled: true, rotate: true);
  print(
    'PASS scoped/pooled owner revocation and pooled key rotation cancel held HTTP, single send',
  );
}
