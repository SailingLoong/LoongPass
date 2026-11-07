import 'dart:async';
import 'dart:convert';
import '../lib/workbuddy_accounts.dart';
import '../lib/workbuddy_account_flow.dart';
import '../lib/workbuddy_vault.dart';
import '../lib/workbuddy_model_provider.dart';
import '../lib/model_provider.dart';
import '../lib/model_http.dart';
import '../tool/workbuddy_single_checks.dart' show Server, VaultStore;
import '../tool/workbuddy_multi_checks.dart' show Memory;

void check(bool ok, String why) {
  if (!ok) throw StateError(why);
}

class Wire implements ModelTransport {
  final calls = <(Uri, Map<String, String>, Object?)>[];
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
    check(isCurrent(), 'no account lease');
    calls.add((uri, headers, body));
    check(uri.host == 'copilot.tencent.com', 'login host reused for inference');
    final value = method == 'GET'
        ? jsonEncode({
            'code': 0,
            'data': {
              'agents': [
                {
                  'name': 'cli',
                  'models': ['claude-live', 'chat-live'],
                },
              ],
              'models': [
                {
                  'id': 'claude-live',
                  'name': 'Claude',
                  'maxInputTokens': 200000,
                  'maxOutputTokens': 8192,
                },
                {
                  'id': 'chat-live',
                  'name': 'Chat',
                  'maxInputTokens': 131072,
                  'maxOutputTokens': 4096,
                },
              ],
            },
          })
        : 'data: {"ok":true}\n\n';
    await consume(
      ModelReply(
        200,
        method == 'GET' ? 'application/json' : 'text/event-stream',
        Stream.value(utf8.encode(value)),
      ),
    );
  }
}

Future<void> main() async {
  final now = DateTime.utc(2026, 11, 7);
  final saved = VaultStore();
  final vault = WorkBuddyVault(saved, now: () => now);
  final a = Server('A'), b = Server('B');
  final queue = [a, b];
  var generation = 0;
  WorkBuddyAccounts roster() => WorkBuddyAccounts(
    create: () => WorkBuddyAccountFlow(
      exchange: queue.removeAt(0),
      store: Memory(),
      now: () => now,
      ownerGeneration: 'model-${++generation}',
      isOwnerCurrent: () => true,
    ),
  );
  var owner = roster();
  final wire = Wire();
  try {
    for (var i = 0; i < 2; i++) {
      final grant = (await owner.beginAuthorization())!;
      check(
        await owner.pollAndSave(grant.sessionId, vault) != null,
        'not saved',
      );
    }
    var source = WorkBuddyModelProvider(owner, transport: wire);
    final accounts = await source.accounts();
    check(
      accounts.length == 2 &&
          accounts.every((x) => !x.id.startsWith('session-')),
      'ephemeral binding',
    );
    final first = accounts.first;
    final catalog = await source.discoverModels(first.id);
    check(
      catalog.models.first.protocol == ModelProtocol.messages &&
          catalog.models.last.protocol == ModelProtocol.chat,
      'mixed protocols lost',
    );
    check(
      catalog.models.first.contextWindow == 200000 &&
          catalog.models.last.outputLimit == 4096,
      'absolute token limits',
    );
    for (final protocol in ModelProtocol.values) {
      final body = <String, dynamic>{
        'model': protocol == ModelProtocol.messages
            ? 'claude-live'
            : 'chat-live',
        'messages': [
          {
            'role': 'user',
            'content': 'Use the exact original system and tools',
          },
        ],
        'stream': true,
      };
      await source.dispatch(
        first.id,
        catalog.registrationId,
        protocol,
        body,
        (r) async {
          await r.body.drain<void>();
        },
        isCurrent: () => true,
        cancelled: Completer<void>().future,
      );
      check(identical(wire.calls.last.$3, body), 'request was rewritten');
      check(
        wire.calls.last.$1.path ==
            (protocol == ModelProtocol.messages
                ? '/v1/messages'
                : '/v2/chat/completions'),
        'wrong wire route',
      );
      check(
        wire.calls.last.$2['X-User-Id'] == 'A' &&
            wire.calls.last.$2['X-Domain'] == 'www.workbuddy.cn',
        'wrong account context',
      );
    }
    owner.close();
    queue.addAll([b, a]);
    owner = roster();
    await owner.restoreSaved(
      vault,
      () async => saved.rows.keys.toList().reversed.toList(),
    );
    source = WorkBuddyModelProvider(owner, transport: wire);
    final restored = (await source.accounts()).firstWhere(
      (x) => x.id == first.id,
    );
    check(
      restored.registrationId == catalog.registrationId,
      'restart changed binding',
    );
    await source.discoverModels(first.id);
    final count = wire.calls.length;
    final slot = owner.accounts.firstWhere((x) => x.uid == 'A');
    await owner.revokeStored(slot.id);
    var failed = false;
    try {
      await source.discoverModels(first.id);
    } catch (_) {
      failed = true;
    }
    check(failed && wire.calls.length == count, 'revoked account dispatched');
    check(a.posts == 0 && b.posts == 0, 'inference claimed reward');
    print(
      'PASS WorkBuddy stable saved identity, mixed protocols, exact limits and revocation',
    );
  } finally {
    owner.close();
    vault.close();
  }
}
