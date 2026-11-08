import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/minimax_accounts.dart';
import '../lib/minimax_model_provider.dart';
import '../lib/minimax_http.dart';
import '../lib/minimax_oauth.dart';
import '../lib/model_provider.dart';
import 'memory_account_store.dart';
import 'minimax_accounts_checks.dart' as account;
import 'minimax_model_checks.dart' as model;

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

class Wire extends model.Wire {
  int status = 200;
  Object answer = {
    'type': 'message',
    'content': [
      {'type': 'text', 'text': 'ok'},
    ],
  };
  String? errorCode;
  int? retryAfterSeconds;

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
    if (method == 'GET') {
      return super.exchange(
        uri,
        headers: headers,
        isCurrent: isCurrent,
        consume: consume,
      );
    }
    check(isCurrent(), 'invalid inference lease');
    calls.add((uri, headers, body));
    await consume(
      ModelReply(
        status,
        'application/json',
        Stream.value(utf8.encode(jsonEncode(answer))),
        errorCode: errorCode,
        retryAfterSeconds: retryAfterSeconds,
      ),
    );
  }
}

Future<void> main() async {
  var failed = 0;
  Future<void> run(String name, Future<void> Function() test) async {
    try {
      await test();
      print('PASS $name');
    } catch (e) {
      failed++;
      print('FAIL $name: $e');
    }
  }

  Future<void> withSource(
    Future<void> Function(
      MiniMaxModelProvider,
      MiniMaxAccounts,
      account.FakeHttp,
      Wire,
      MiniMaxAccount,
      String,
    )
    use, {
    String region = 'cn',
  }) async {
    final http = account.FakeHttp();
    final owner = MiniMaxAccounts(
      store: MiniMaxAccountStore(MemoryAccountStore('minimax-model-alignment')),
      http: http,
      nowMs: () => 100000,
    );
    try {
      final credential = MiniMaxCredential.authorization(
        const MiniMaxOAuthToken(
          'synthetic-access',
          3700000,
          'synthetic-refresh',
        ),
        region,
      );
      final saved = await owner.save(
        await owner.verifySource(() async => credential, confirmed: true),
        confirmed: true,
      );
      final wire = Wire();
      final source = MiniMaxModelProvider(owner, region, transport: wire);
      final catalog = await source.discoverModels(saved.id);
      await use(source, owner, http, wire, saved, catalog.registrationId);
    } finally {
      owner.dispose();
    }
  }

  final body = <String, dynamic>{
    'model': 'vendor-model',
    'messages': [
      {'role': 'user', 'content': 'hello'},
    ],
    'thinking': {'type': 'adaptive'},
    'output_config': {'effort': 'high'},
    'tools': [
      {
        'name': 'echo',
        'input_schema': {'type': 'object'},
      },
    ],
  };
  Future<void> send(
    MiniMaxModelProvider source,
    MiniMaxAccount saved,
    String registration,
    Future<void> Function(ModelReply) consume, {
    ModelRequestContext? context,
  }) => source.dispatch(
    saved.id,
    registration,
    ModelProtocol.messages,
    body,
    consume,
    isCurrent: () => true,
    cancelled: Completer<void>().future,
    context: context,
  );

  await run(
    'MiniMax CN and global retain their own catalog and inference origins',
    () async {
      for (final region in ['cn', 'global']) {
        await withSource((
          source,
          owner,
          http,
          wire,
          saved,
          registration,
        ) async {
          final host = region == 'cn' ? 'agent.minimax.cn' : 'agent.minimax.io';
          check(
            wire.calls.single.$1.host == host &&
                wire.calls.single.$1.queryParameters['region'] ==
                    (region == 'cn' ? 'cn' : 'en'),
            'catalog crossed regional authorization boundaries',
          );
          await send(
            source,
            saved,
            registration,
            (r) async => r.body.drain<void>(),
          );
          check(
            wire.calls.last.$1.host == host,
            'inference crossed regional authorization boundaries',
          );
        }, region: region);
      }
    },
  );

  await run(
    'MiniMax preserves true session, agent, beta and native request body',
    () => withSource((source, owner, http, wire, saved, registration) async {
      final context = ModelRequestContext.fromRequest(
        body,
        session: 'chat:worker-1',
        scope: 'minimax-account',
        anthropicBeta: 'interleaved-thinking-2025-05-14',
      );
      for (var i = 0; i < 2; i++) {
        await send(
          source,
          saved,
          registration,
          (r) async => r.body.drain<void>(),
          context: context,
        );
        final sent = wire.calls.last;
        check(
          sent.$2['x-mavis-session-id'] == context.sessionId &&
              sent.$2['x-mavis-agent-id'] == 'worker-1' &&
              sent.$2['anthropic-beta'] == 'interleaved-thinking-2025-05-14',
          'supplier context was discarded',
        );
        check(
          identical(sent.$3, body),
          'native Messages parameters were rewritten',
        );
      }
    }),
  );

  await run(
    'MiniMax unknown sessions stay fresh even for identical first text',
    () => withSource((source, owner, http, wire, saved, registration) async {
      await send(
        source,
        saved,
        registration,
        (r) async => r.body.drain<void>(),
      );
      final first = wire.calls.last.$2['x-mavis-session-id'];
      await send(
        source,
        saved,
        registration,
        (r) async => r.body.drain<void>(),
      );
      check(
        first != wire.calls.last.$2['x-mavis-session-id'],
        'unknown conversations collided',
      );
    }),
  );

  await run(
    'MiniMax live catalog retains modality and reasoning controls',
    () => withSource((source, owner, http, wire, saved, registration) async {
      wire.catalog = {
        'providers': [
          {
            'providerId': 'minimax',
            'config': {
              'models': {
                'MiniMax-Future': {
                  'name': 'Future model',
                  'limit': {'context': 1000000, 'output': 128000},
                  'modalities': {
                    'input': ['text', 'image'],
                  },
                  'thinking_config': {'mode': 'forced_on'},
                  'thinking': {
                    'effortOptions': ['default', 'low', 'high'],
                    'defaultEffort': 'high',
                  },
                },
              },
            },
          },
        ],
      };
      final definition = (await source.discoverModels(saved.id)).models.single;
      check(
        definition.images == true &&
            definition.tools == true &&
            definition.reasoning == true &&
            definition.alwaysThinks == true &&
            jsonEncode(definition.reasoningEfforts) == '["low","high"]' &&
            definition.defaultReasoningEffort == 'high' &&
            definition.contextWindow == 1000000 &&
            definition.outputLimit == 128000,
        'catalog capabilities or absolute limits were lost',
      );
    }),
  );

  await run(
    'only MiniMax quota refusals become429 and retain retry metadata',
    () => withSource((source, owner, http, wire, saved, registration) async {
      for (final sample in [
        (402, '积分余额不足', 429, 'quota_exhausted'),
        (403, 'quota exhausted', 429, 'quota_exhausted'),
        (403, 'insufficient permissions', 403, 'permission_denied'),
      ]) {
        wire.status = sample.$1;
        wire.answer = {
          'type': 'error',
          'error': {'message': sample.$2},
        };
        wire.errorCode = 'permission_denied';
        wire.retryAfterSeconds = 91;
        final before = wire.calls.length;
        await send(source, saved, registration, (r) async {
          check(
            r.status == sample.$3 &&
                r.errorCode == sample.$4 &&
                r.retryAfterSeconds == 91,
            'quota or unrelated refusal misclassified',
          );
          check(
            (await utf8.decoder.bind(r.body).join()) == jsonEncode(wire.answer),
            'upstream error body was lost',
          );
        });
        check(
          wire.calls.length == before + 1,
          'refused inference was replayed',
        );
      }
      wire.status = 403;
      wire.answer = {
        'error': {'type': 'permission_error'},
        'model': 'quota-model',
      };
      await send(source, saved, registration, (r) async {
        check(
          r.status == 403 && r.errorCode == 'permission_denied',
          'an unrelated JSON field was treated as a quota refusal',
        );
        await r.body.drain<void>();
      });
    }),
  );

  await run(
    'MiniMax401 refreshes through its owner on the next independent request',
    () => withSource((source, owner, http, wire, saved, registration) async {
      wire.status = 401;
      await send(source, saved, registration, (r) async {
        check(r.status == 401, '401 response changed');
        await r.body.drain<void>();
      });
      check(
        wire.calls.length == 2 && http.refreshCalls == 0,
        '401 was replayed or refreshed inside its lease',
      );
      wire.status = 200;
      await send(
        source,
        saved,
        registration,
        (r) async => r.body.drain<void>(),
      );
      check(
        http.refreshCalls == 1 &&
            wire.calls.last.$2['Authorization'] == 'Bearer synthetic-new',
        'next request reused refused credentials',
      );
      await owner.rejectInferenceAuthorization(
        saved.id,
        registration,
        'synthetic-access',
      );
      await send(
        source,
        saved,
        registration,
        (r) async => r.body.drain<void>(),
      );
      check(
        http.refreshCalls == 1,
        'late old-token rejection invalidated a newer authorization',
      );
    }),
  );

  await run(
    'MiniMax refuses fallback to a401-rejected token after temporary refresh failure',
    () => withSource((source, owner, http, wire, saved, registration) async {
      wire.status = 401;
      await send(
        source,
        saved,
        registration,
        (r) async => r.body.drain<void>(),
      );
      http.refreshed = const MiniMaxReply(503, null);
      final before = wire.calls.length;
      var rejected = false;
      try {
        await send(
          source,
          saved,
          registration,
          (r) async => r.body.drain<void>(),
        );
      } on MiniMaxAccountError catch (e) {
        rejected = e.code == 'NetworkUnavailable';
      }
      check(
        rejected && wire.calls.length == before && http.refreshCalls == 1,
        'refused access token was used as fallback',
      );
    }),
  );
  exitCode = failed == 0 ? 0 : 1;
}
