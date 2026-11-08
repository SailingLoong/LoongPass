import 'dart:async';
import 'dart:convert';
import '../lib/model_http.dart';
import '../lib/model_provider.dart';
import '../lib/workbuddy_account_flow.dart';
import '../lib/workbuddy_accounts.dart';
import '../lib/workbuddy_api.dart';
import '../lib/workbuddy_model_provider.dart';
import '../lib/workbuddy_vault.dart';
import '../tool/workbuddy_single_checks.dart' show Server, VaultStore;
import '../tool/workbuddy_multi_checks.dart' show Memory;

void check(bool value, String why) {
  if (!value) throw StateError(why);
}

class RenewalStore extends VaultStore {
  bool failRotationSave = false;
  bool failRejectionSave = false,
      loseRejectionAck = false,
      loseRotationAck = false;
  @override
  Future<bool> compareExchange(
    String key,
    int? expected,
    Map<String, Object?> value,
  ) async {
    if (failRejectionSave &&
        value['accessRejected'] == true &&
        value['state'] == 'active')
      throw StateError('synthetic unavailable store');
    if (failRotationSave && value['state'] == 'active' && expected == 2)
      return false;
    final saved = await super.compareExchange(key, expected, value);
    if (saved &&
        loseRejectionAck &&
        value['accessRejected'] == true &&
        value['state'] == 'active') {
      loseRejectionAck = false;
      throw StateError('synthetic lost rejection acknowledgement');
    }
    if (saved &&
        loseRotationAck &&
        value['accessToken'] == 'synthetic-renewed' &&
        value['state'] == 'active') {
      loseRotationAck = false;
      throw StateError('synthetic lost rotation acknowledgement');
    }
    return saved;
  }
}

class RenewalServer extends Server {
  RenewalServer(super.uid);
  int renewals = 0;
  bool unknownRenewal = false;
  Completer<void>? renewalWait;
  @override
  Future<Map<String, Object?>> send(
    WorkBuddyRequest request,
    bool Function() admitted,
  ) async {
    if (request.uri.path.endsWith('/auth/token/refresh')) {
      check(admitted(), 'refresh after retirement');
      check(
        request.headers['X-Refresh-Token'] == 'synthetic-refresh',
        'refresh lost its saved owner',
      );
      renewals++;
      await renewalWait?.future;
      if (unknownRenewal) throw const WorkBuddyApiFailure('OutcomeUnknown');
      return {
        'code': 0,
        'data': {
          'accessToken': 'synthetic-renewed',
          'refreshToken': 'synthetic-next-refresh',
          'expiresIn': 3600,
          'refreshExpiresIn': 604800,
        },
      };
    }
    if (request.uri.path == '/v2/plugin/account' &&
        request.headers['Authorization'] == 'Bearer synthetic-renewed') {
      check(
        admitted() && request.headers['X-Domain'] == domain,
        'renewed identity crossed owners',
      );
      return {
        'code': 0,
        'data': {'uid': uid, 'domain': domain, 'type': 'personal'},
      };
    }
    final response = await super.send(request, admitted);
    if (request.uri.path.endsWith('/auth/token'))
      return {
        ...response,
        'data': {
          ...Map<String, Object?>.from(response['data'] as Map),
          'refreshToken': 'synthetic-refresh',
          'refreshExpiresIn': 604800,
        },
      };
    return response;
  }
}

class Wire implements ModelTransport {
  final calls = <({Uri uri, Map<String, String> headers, Object? body})>[];
  int status = 200;
  bool alwaysThinks = false;
  bool? reasoning = true;
  bool credentialRejected = false;
  Completer<void>? replyWait;
  Stream<List<int>> Function()? replyBody;
  Object? rejected;
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
    check(isCurrent(), 'stale inference lease');
    calls.add((uri: uri, headers: headers, body: body));
    if (method == 'POST') await replyWait?.future;
    final request = body is Map ? body : const {};
    final name =
        request['tools'] is List && (request['tools'] as List).isNotEmpty
        ? request['tools'][0]['function']['name']
        : 'echo';
    final value = method == 'GET'
        ? {
            'code': 0,
            'data': {
              'agents': [
                {
                  'name': 'cli',
                  'models': ['glm-5.3', 'claude-opus-5.5'],
                },
              ],
              'models': [
                {
                  'id': 'glm-5.3',
                  'name': 'GLM-5.3',
                  'maxInputTokens': 1000000,
                  'maxOutputTokens': 32768,
                  'supportsImages': true,
                  if (reasoning != null) 'supportsReasoning': reasoning,
                  if (alwaysThinks) 'onlyReasoning': true,
                  if (reasoning == true)
                    'reasoning': {
                      'supportedEfforts': ['low', 'high', 'max'],
                      'defaultEffort': 'high',
                      'canDisableThinking': !alwaysThinks,
                    },
                },
                {
                  'id': 'claude-opus-5.5',
                  'name': 'Claude-Opus-5.5',
                  'supportsImages': true,
                  if (reasoning != null) 'supportsReasoning': reasoning,
                  if (alwaysThinks) 'onlyReasoning': true,
                  if (reasoning == true)
                    'reasoning': {
                      'supportedEfforts': ['low', 'high', 'xhigh'],
                    },
                },
              ],
            },
          }
        : {
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': '',
                  'tool_calls': [
                    {
                      'id': 'call-1',
                      'type': 'function',
                      'function': {'name': name, 'arguments': '{}'},
                    },
                  ],
                },
                'finish_reason': 'tool_calls',
              },
            ],
          };
    await consume(
      ModelReply(
        status,
        'application/json',
        replyBody?.call() ??
            Stream.value(utf8.encode(jsonEncode(rejected ?? value))),
        credentialRejected: credentialRejected,
      ),
    );
  }
}

class Rig {
  DateTime now = DateTime.utc(2026, 11, 8);
  final RenewalStore store = RenewalStore();
  final RenewalServer server = RenewalServer('A');
  final Wire wire = Wire();
  late final WorkBuddyVault vault = WorkBuddyVault(store, now: () => now);
  late WorkBuddyAccounts owner = roster();
  WorkBuddyAccounts roster() => WorkBuddyAccounts(
    create: () => WorkBuddyAccountFlow(
      exchange: server,
      store: Memory(),
      now: () => now,
      ownerGeneration: 'alignment',
      isOwnerCurrent: () => true,
    ),
  );
  WorkBuddyModelProvider? _provider;
  WorkBuddyAccounts? _providerOwner;
  WorkBuddyModelProvider get provider {
    if (!identical(_providerOwner, owner)) {
      _providerOwner = owner;
      _provider = WorkBuddyModelProvider(
        owner,
        transport: wire,
        clientInfo: () async => WorkBuddyClientInfo.fromNative({
          'appVersion': '6.0.1',
          'cliVersion': '3.1.7',
          'applicationName': 'WorkBuddy',
        }),
      );
    }
    return _provider!;
  }

  Future<void> login() async {
    final grant = (await owner.beginAuthorization())!;
    check(
      await owner.pollAndSave(grant.sessionId, vault) != null,
      'login failed',
    );
  }

  void close() {
    owner.close();
    vault.close();
  }

  Future<String> send(
    Map<String, dynamic> body, {
    ModelRequestContext? context,
    ModelProtocol protocol = ModelProtocol.chat,
  }) async {
    final account = (await provider.accounts()).single;
    var text = '';
    await provider.dispatch(
      account.id,
      account.registrationId!,
      protocol,
      body,
      (reply) async {
        text = await utf8.decoder.bind(reply.body).join();
      },
      isCurrent: () => true,
      cancelled: Completer<void>().future,
      context: context,
    );
    return text;
  }
}

Map<String, dynamic> chat([Map<String, dynamic> extra = const {}]) => {
  'model': 'glm-5.3',
  'stream': true,
  'messages': [
    {'role': 'user', 'content': 'hello'},
  ],
  ...extra,
};

Future<void> main() async {
  var failures = 0;
  Future<void> test(String name, Future<void> Function(Rig) run) async {
    final rig = Rig();
    try {
      await rig.login();
      await run(rig);
      print('PASS $name');
    } catch (e) {
      failures++;
      print('FAIL $name: $e');
    } finally {
      rig.close();
    }
  }

  await test('CLI catalog publishes real capability and effort facts', (
    r,
  ) async {
    final info = WorkBuddyClientInfo.fromNative({
      'appVersion': '6.0.1.2',
      'cliVersion': '3.1.7',
      'applicationName': 'WorkBuddy',
    });
    check(
      info.userAgent == 'WorkBuddy/6.0.1.2 WorkBuddy/6.0.1.2 CLI/3.1.7',
      'installed app version was changed',
    );
    for (final invalid in [
      {'appVersion': '6.0.1', 'applicationName': 'WorkBuddy'},
      {
        'appVersion': '6.0.1',
        'cliVersion': '3.1.7\n',
        'applicationName': 'WorkBuddy',
      },
    ]) {
      var refused = false;
      try {
        WorkBuddyClientInfo.fromNative(invalid);
      } on FormatException {
        refused = true;
      }
      check(refused, 'incomplete or unsafe client metadata accepted');
    }
    final a = (await r.provider.accounts()).single;
    final models = (await r.provider.discoverModels(a.id)).models;
    check(
      r.wire.calls.last.headers['User-Agent'] ==
          'WorkBuddy/6.0.1 WorkBuddy/6.0.1 CLI/3.1.7',
      'catalog did not use the installed CLI identity',
    );
    final glm = models.first;
    check(
      glm.contextWindow == 1000000 &&
          glm.outputLimit == 32768 &&
          glm.images == true &&
          glm.tools == true &&
          glm.reasoningEfforts.join(',') == 'none,low,high,max' &&
          glm.defaultReasoningEffort == 'high',
      'CLI facts missing',
    );
    check(
      models.last.protocol == ModelProtocol.messages &&
          models.last.reasoningEfforts.contains('max'),
      'native Claude effort or protocol lost',
    );
  });
  await test(
    'Chat normalizes supplier spellings and restores declared tool names',
    (r) async {
      final a = (await r.provider.accounts()).single;
      await r.provider.discoverModels(a.id);
      final body = chat({
        'max_completion_tokens': 4000,
        'messages': [
          {'role': 'developer', 'content': 'Keep original instructions.'},
          {
            'role': 'assistant',
            'content': '',
            'reasoning_content': 'Earlier thought.',
          },
          {'role': 'user', 'content': 'Read it.'},
        ],
        'tools': [
          {
            'type': 'function',
            'function': {
              'name': 'fs.read',
              'parameters': {
                'oneOf': [
                  {
                    'type': 'object',
                    'properties': {
                      'path': {
                        'enum': ['a', 'b'],
                      },
                    },
                  },
                  {
                    'type': 'object',
                    'properties': {
                      'line': {'type': 'integer'},
                    },
                  },
                ],
              },
            },
          },
        ],
        'tool_choice': {
          'type': 'function',
          'function': {'name': 'fs.read'},
        },
      });
      final before = jsonEncode(body), answer = jsonDecode(await r.send(body));
      final sent = r.wire.calls.last.body as Map;
      check(
        sent['max_tokens'] == 4000 &&
            !sent.containsKey('max_completion_tokens') &&
            sent['messages'][0]['role'] == 'system' &&
            sent['messages'][0]['content'] == 'Keep original instructions.' &&
            sent['messages'][1]['reasoning'] == 'Earlier thought.' &&
            !sent['messages'][1].containsKey('reasoning_content'),
        'Chat vendor spellings missing',
      );
      check(
        sent['tools'][0]['function']['name'] == 'fs_read' &&
            sent['tool_choice'] == 'fs_read' &&
            sent['tools'][0]['function']['parameters']['type'] == 'object',
        'tool not fitted',
      );
      check(
        answer['choices'][0]['message']['tool_calls'][0]['function']['name'] ==
                'fs.read' &&
            jsonEncode(body) == before,
        'reply names not restored or caller changed',
      );
    },
  );
  await test(
    'default thinking uses catalog while explicit off and short asks remain off',
    (r) async {
      final a = (await r.provider.accounts()).single;
      await r.provider.discoverModels(a.id);
      await r.send(chat());
      check(
        (r.wire.calls.last.body as Map)['reasoning_effort'] == 'high',
        'default effort missing',
      );
      await r.send(chat({'max_tokens': 64}));
      check(
        !(r.wire.calls.last.body as Map).containsKey('reasoning_effort'),
        'title budget consumed by default thinking',
      );
      await r.send(
        chat({
          'reasoning_effort': 'none',
          'tools': [
            {
              'type': 'function',
              'function': {'name': 'echo'},
            },
          ],
          'tool_choice': 'none',
        }),
      );
      check(
        (r.wire.calls.last.body as Map)['reasoning_effort'] == 'none' &&
            !(r.wire.calls.last.body as Map).containsKey('tools'),
        'explicit switches ignored',
      );
    },
  );
  await test('mandatory thinking rejects explicit off before a model POST', (
    r,
  ) async {
    r.wire.alwaysThinks = true;
    final a = (await r.provider.accounts()).single;
    await r.provider.discoverModels(a.id);
    final requests = [
      (ModelProtocol.chat, chat({'reasoning_effort': 'none'})),
      (ModelProtocol.chat, chat({'reasoning_effort': 'off'})),
      (
        ModelProtocol.chat,
        chat({
          'reasoning': {'effort': 'none'},
        }),
      ),
      (
        ModelProtocol.messages,
        chat({
          'model': 'claude-opus-5.5',
          'thinking': {'type': 'disabled'},
        }),
      ),
      (
        ModelProtocol.messages,
        chat({
          'model': 'claude-opus-5.5',
          'thinking': {'type': 'between_tools'},
        }),
      ),
    ];
    for (final (protocol, request) in requests) {
      final before = r.wire.calls.length;
      var refused = false;
      try {
        await r.send(request, protocol: protocol);
      } on ModelServiceFailure catch (failure) {
        refused = failure.code == 'unsupported_reasoning_effort';
      }
      check(
        refused && r.wire.calls.length == before,
        '$protocol explicit thinking off reached the model',
      );
    }
    await r.send(chat());
    check(
      (r.wire.calls.last.body as Map)['reasoning_effort'] == 'high',
      'implicit default was rejected or changed',
    );
  });
  await test('tool unions resolve normalized local schema definitions', (
    r,
  ) async {
    await r.send(
      chat({
        'tools': [
          {
            'type': 'function',
            'function': {
              'name': 'choose',
              'parameters': {
                r'$defs': {
                  'A': {
                    'type': 'object',
                    'properties': {
                      'kind': {
                        'enum': ['a', 'b'],
                      },
                    },
                  },
                  'B': {
                    'type': 'object',
                    'properties': {
                      'line': {'type': 'integer'},
                    },
                  },
                },
                'oneOf': [
                  {r'$ref': r'#/$defs/A'},
                  {r'$ref': r'#/$defs/B'},
                ],
              },
            },
          },
        ],
      }),
    );
    final parameters =
        (r.wire.calls.last.body as Map)['tools'][0]['function']['parameters'];
    check(
      parameters['properties']['kind']['type'] == 'string' &&
          parameters['properties']['line']['type'] == 'integer',
      'root union used stale unnormalized definitions',
    );
  });
  await test('native Messages preserves original system and signed thinking', (
    r,
  ) async {
    final body = {
      'model': 'claude-opus-5.5',
      'stream': true,
      'system': [
        {'type': 'text', 'text': 'Original Claude Code system.'},
      ],
      'messages': [
        {
          'role': 'assistant',
          'content': [
            {
              'type': 'thinking',
              'thinking': 'Original thought.',
              'signature': 'original-signature',
            },
            {'type': 'text', 'text': 'ok'},
          ],
        },
        {'role': 'user', 'content': 'continue'},
      ],
      'output_config': {'effort': 'max'},
    };
    await r.send(body, protocol: ModelProtocol.messages);
    check(
      jsonEncode(r.wire.calls.last.body) == jsonEncode(body),
      'native content rewritten',
    );
  });
  await test(
    'account-scoped conversation and user-turn headers follow context',
    (r) async {
      final first = chat();
      final context = ModelRequestContext.fromRequest(
        first,
        session: 'session:worker',
      ).forAccount('workbuddy-cn/A/registration');
      await r.send(first, context: context);
      final headers = r.wire.calls.last.headers;
      check(
        headers['X-Conversation-ID'] == context.sessionId.replaceAll('-', '') &&
            headers['X-Conversation-Request-ID'] ==
                context.turnId.replaceAll('-', '') &&
            headers['X-Conversation-Message-ID'] ==
                context.requestId.replaceAll('-', '') &&
            headers['X-Request-ID'] == headers['X-Conversation-Message-ID'],
        'vendor IDs not mapped from neutral context',
      );
    },
  );
  await test(
    'known nonreasoning sources refuse explicit on and unknown stays unknown',
    (r) async {
      final a = (await r.provider.accounts()).single;
      r.wire.reasoning = false;
      check(
        (await r.provider.discoverModels(
          a.id,
        )).models.every((m) => m.reasoning == false),
        'explicit false capability lost',
      );
      for (final (protocol, request) in [
        (ModelProtocol.chat, chat({'reasoning_effort': 'high'})),
        (
          ModelProtocol.messages,
          chat({
            'model': 'claude-opus-5.5',
            'thinking': {'type': 'adaptive'},
          }),
        ),
      ]) {
        final before = r.wire.calls.length;
        var refused = false;
        try {
          await r.send(request, protocol: protocol);
        } on ModelServiceFailure catch (failure) {
          refused = failure.code == 'unsupported_reasoning_effort';
        }
        check(
          refused && r.wire.calls.length == before,
          'unsupported explicit thinking on reached vendor',
        );
      }
      await r.send(chat());
      r.wire.reasoning = null;
      check(
        (await r.provider.discoverModels(
          a.id,
        )).models.every((m) => m.reasoning == null),
        'unknown capability was advertised as false',
      );
      r.wire.alwaysThinks = true;
      check(
        (await r.provider.discoverModels(
          a.id,
        )).models.every((m) => m.reasoning == true && m.alwaysThinks == true),
        'onlyReasoning fact depended on an optional effort list',
      );
    },
  );
  await test(
    'vendor failures expose safe classification without repeating a send',
    (r) async {
      r.wire.status = 403;
      r.wire.rejected = {
        'code': 14018,
        'msg': 'credits exhausted synthetic-private-canary',
      };
      final reply = jsonDecode(await r.send(chat()));
      check(
        reply['error']['type'] == 'quota_exhausted' &&
            !jsonEncode(reply).contains('synthetic-private-canary') &&
            r.wire.calls.length == 1,
        'vendor quota error lost or exposed raw content',
      );
    },
  );
  await test('browser grant saves renewable credentials with access expiry', (
    r,
  ) async {
    final saved = r.store.rows.values.single;
    check(
      saved['refreshToken'] == 'synthetic-refresh' &&
          saved['refreshExpiresAt'] ==
              DateTime.utc(2026, 11, 15).millisecondsSinceEpoch,
      'refresh grant discarded',
    );
  });
  await test(
    'renewal is saved before inference and keeps registration identity',
    (r) async {
      final before = (await r.provider.accounts()).single.registrationId;
      r.now = r.now.add(const Duration(seconds: 3540));
      await r.send(chat());
      check(
        r.server.renewals == 1 &&
            r.wire.calls.last.headers['Authorization'] ==
                'Bearer synthetic-renewed' &&
            r.store.rows.values.single['accessToken'] == 'synthetic-renewed' &&
            (await r.provider.accounts()).single.registrationId == before,
        'inference used stale grant or rotated registration',
      );
      await r.send(chat());
      check(r.server.renewals == 1, 'saved refresh token spent twice');
    },
  );
  await test('expired renewable grant restores through owner before use', (
    r,
  ) async {
    final before = (await r.provider.accounts()).single.registrationId;
    r.owner.close();
    r.now = r.now.add(const Duration(hours: 2));
    r.owner = r.roster();
    check(
      await r.owner.restoreSaved(
            r.vault,
            () async => r.store.rows.keys.toList(),
          ) ==
          1,
      'renewable saved grant did not restore',
    );
    await r.send(chat());
    check(
      r.server.renewals == 1 &&
          (await r.provider.accounts()).single.registrationId == before,
      'restore duplicated renewal or registration',
    );
  });
  for (final saveFailure in [false, true]) {
    await test(
      'uncertain ${saveFailure ? 'save' : 'renewal'} cannot dispatch or refresh again',
      (r) async {
        r.server.unknownRenewal = !saveFailure;
        r.store.failRotationSave = saveFailure;
        r.now = r.now.add(const Duration(seconds: 3540));
        for (var i = 0; i < 2; i++) {
          try {
            await r.send(chat());
          } catch (_) {}
        }
        check(
          r.server.renewals == 1 &&
              r.wire.calls.isEmpty &&
              r.store.rows.values.single['state'] == 'rotationPending',
          'uncertain refresh resent or inference escaped',
        );
        r.owner.close();
        r.owner = r.roster();
        check(
          await r.owner.restoreSaved(
                    r.vault,
                    () async => r.store.rows.keys.toList(),
                  ) ==
                  0 &&
              r.server.renewals == 1,
          'restart retried uncertain refresh',
        );
      },
    );
  }
  await test(
    'revocation during renewal prevents late inference and credential revival',
    (r) async {
      r.server.renewalWait = Completer<void>();
      r.now = r.now.add(const Duration(seconds: 3540));
      final action = r.send(chat()).then<void>((_) {}, onError: (Object _) {});
      while (r.server.renewals == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await r.owner.revokeStored(r.owner.accounts.single.id);
      r.server.renewalWait!.complete();
      await action;
      check(
        r.wire.calls.isEmpty &&
            r.store.rows.values.single['state'] == 'revoked' &&
            (await r.provider.accounts()).isEmpty,
        'retired lifetime revived after refresh',
      );
    },
  );
  if (failures != 0)
    throw StateError('$failures WorkBuddy alignment regressions');
}
