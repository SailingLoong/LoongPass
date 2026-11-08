// macOS acceptance entry point. Uses LoongPass's native saved-account owners;
// never starts reward timers, logs credentials, or creates a platform login.
// Build only as a test target with MODEL_POOLING_REPORT set to a private path.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../lib/account_document_store.dart';
import '../lib/minimax_accounts.dart';
import '../lib/workbuddy_api.dart';
import '../lib/workbuddy_claim.dart';
import '../lib/zcode_api.dart';
import '../lib/rewards/reward_provider.dart';
import '../lib/model_service.dart';
import '../lib/model_http.dart';
import '../lib/zcode_activity_accounts.dart';
import '../lib/credit_summary.dart';
import '../lib/native_minimax_accounts.dart';
import '../lib/minimax_model_provider.dart';
import '../lib/loomy_model_provider.dart';
import '../lib/workbuddy_accounts.dart';
import '../lib/workbuddy_flutter.dart';
import '../lib/workbuddy_desktop_flutter.dart';
import '../lib/workbuddy_vault.dart';
import '../lib/workbuddy_vault_flutter.dart';
import '../lib/workbuddy_model_provider.dart';
import '../lib/qoder_device_accounts.dart';
import '../lib/qoder_device_flutter.dart';
import '../lib/qoder_model_provider.dart';
import '../lib/native_zcode_activity.dart';
import '../lib/zcode_model_provider.dart';
import '../lib/native_account_document_store.dart';
import '../lib/rewards/reward_accounts.dart';
import '../lib/rewards/reward_providers.dart';
import '../lib/rewards/reward_transport.dart';

String _failure(Object e) {
  final code = switch (e) {
    ModelServiceFailure() => e.code,
    MiniMaxAccountError() => e.code,
    WorkBuddyApiFailure() => e.code,
    WorkBuddyFailure() => e.code,
    QoderAccountError() => e.code,
    ZcodeFailure() => e.code,
    RewardFailure() => e.code,
    _ => 'operation_unavailable',
  };
  return RegExp(r'^[A-Za-z0-9_]{1,80}$').hasMatch(code)
      ? code
      : 'operation_unavailable';
}

class _ObservedProvider extends ModelProvider {
  _ObservedProvider(this.source, this.calls);
  final ModelProvider source;
  final List<Map<String, dynamic>> calls;
  final aliases = <String, String>{};
  @override
  String get id => source.id;
  @override
  String get name => source.name;
  @override
  Set<ModelProtocol> get protocols => source.protocols;
  @override
  Stream<void> get changes => source.changes;
  @override
  Future<List<ModelAccount>> accounts() => source.accounts();
  @override
  Future<ModelCatalog> discoverModels(String accountId) =>
      source.discoverModels(accountId);
  @override
  void validateRequest(ModelProtocol protocol, Map<String, dynamic> body) =>
      source.validateRequest(protocol, body);
  @override
  Future<void> dispatch(
    String accountId,
    String registrationId,
    ModelProtocol protocol,
    Map<String, dynamic> body,
    Future<void> Function(ModelReply) consume, {
    required bool Function() isCurrent,
    required Future<void> cancelled,
  }) async {
    final row = <String, dynamic>{
      'source': id,
      'alias': aliases[accountId],
      'protocol': protocol.name,
      'model': body['model'],
    };
    calls.add(row);
    try {
      await source.dispatch(
        accountId,
        registrationId,
        protocol,
        body,
        (reply) async {
          row['http'] = reply.status;
          await consume(reply);
        },
        isCurrent: isCurrent,
        cancelled: cancelled,
      );
    } catch (error) {
      row['failure'] = _failure(error);
      row['failure_type'] = error.runtimeType.toString();
      rethrow;
    }
  }
}

class _ObservedModels implements ModelTransport {
  _ObservedModels(this.log);
  final List<Map<String, dynamic>> log;
  String alias = '';
  @override
  Future<void> exchange(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const {},
    Object? body,
    required bool Function() isCurrent,
    Future<void>? cancelled,
    required Future<void> Function(ModelReply) consume,
  }) => ModelHttp().exchange(
    uri,
    method: method,
    headers: headers,
    body: body,
    isCurrent: isCurrent,
    cancelled: cancelled,
    consume: (reply) async {
      if (method != 'GET') {
        log.add({
          'host': uri.host,
          'path': uri.path,
          'status': reply.status,
          'content_type': reply.contentType,
        });
        return consume(reply);
      }
      final bytes = <int>[];
      await for (final part in reply.body) {
        if (bytes.length + part.length > 4 * 1024 * 1024)
          throw StateError('limit');
        bytes.addAll(part);
      }
      final row = <String, dynamic>{
        'alias': alias,
        'host': uri.host,
        'path': uri.path,
        'status': reply.status,
      };
      try {
        final value = jsonDecode(utf8.decode(bytes));
        if (value is Map) {
          final code = value['code'];
          if (code is num ||
              code is String && RegExp(r'^-?[0-9]+$').hasMatch(code))
            row['business_code'] = code;
          final data = value['data'];
          if (data is Map) {
            row['data_fields'] = data.keys.take(24).toList();
            final agents = data['agents'];
            if (agents is List)
              row['agent_names'] = [
                for (final a in agents)
                  if (a is Map && a['name'] is String) a['name'],
              ];
          }
        }
      } catch (_) {}
      log.add(row);
      await consume(
        ModelReply(
          reply.status,
          reply.contentType,
          Stream.value(bytes),
          cancel: reply.cancel,
        ),
      );
    },
  );
}

class _ObservedZcode extends ZcodeHttp {
  _ObservedZcode(this.log);
  final List<Map<String, dynamic>> log;
  String alias = '';
  @override
  Future<ZcodeReply> send(
    ZcodeRequest request, {
    bool Function()? isCurrent,
  }) async {
    final reply = await super.send(request, isCurrent: isCurrent);
    if (request.path == ZcodeApi.balancePath) {
      final data = reply.body['data'];
      if (data is Map) {
        final plans = data['plans'] is List ? data['plans'] as List : const [];
        log.add({
          'alias': alias,
          'status': reply.status,
          'server_time': data['server_time'],
          'plans': [
            for (final p in plans)
              if (p is Map)
                {
                  'status': p['status'],
                  'start': p['starts_at'],
                  'end': p['ends_at'],
                },
          ],
          'buckets': [
            for (final b
                in data['balances'] is List ? data['balances'] : const [])
              if (b is Map)
                {
                  'fields': b.keys.toList(),
                  'remaining_units': b['remaining_units'],
                  'capabilities': b['capabilities'],
                  'matches_active': plans.whereType<Map>().any(
                    (p) =>
                        p['user_plan_id'] == b['user_plan_id'] &&
                        p['status'] == 'active',
                  ),
                },
          ],
        });
      }
    }
    return reply;
  }
}

class _Settings implements AccountDocumentStore {
  _Settings(this.file);
  final File file;
  @override
  String get identity => file.path;
  @override
  Future<AccountDocument> read() async {
    if (!await file.exists()) return AccountDocument(0, {});
    final value = jsonDecode(await file.readAsString());
    return AccountDocument(
      value['revision'],
      Map<String, dynamic>.from(value['data']),
    );
  }

  @override
  Future<void> write(int expectedRevision, Map<String, dynamic> data) async {
    if ((await read()).revision != expectedRevision) throw StateError('stale');
    final stage = File('${file.path}.tmp');
    await stage.writeAsString(
      jsonEncode({'revision': expectedRevision + 1, 'data': data}),
      flush: true,
    );
    await Process.run('/bin/chmod', ['600', stage.path]);
    await stage.rename(file.path);
  }
}

Map<String, dynamic> _credits(CreditSummary? c) => c == null
    ? {'status': 'unknown'}
    : {
        'total_remaining': c.totalRemaining,
        'without_known_expiry': c.withoutExpiry,
        'observed_at': c.observedAt.toUtc().toIso8601String(),
        'expiry': [
          for (final e in c.expiring)
            {
              'at': e.expiresAt.toUtc().toIso8601String(),
              'remaining': e.remaining,
            },
        ],
      };
Future<(int, Map<String, dynamic>?, String)> _call(
  ModelService service,
  ModelBinding binding,
  ModelDefinition model,
  Map<String, dynamic> body,
) async {
  final client = HttpClient();
  try {
    final path =
        '/providers/${binding.providerId}/${model.protocol.name}/v1/${model.protocol == ModelProtocol.messages ? 'messages' : 'chat/completions'}';
    final request = await client.postUrl(service.endpoint!.resolve(path));
    request.headers.set('x-api-key', binding.key);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 90));
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 90))) {
      if (bytes.length + chunk.length > 2 * 1024 * 1024)
        throw StateError('response_limit');
      bytes.addAll(chunk);
    }
    final raw = utf8.decode(bytes);
    Map<String, dynamic>? value;
    try {
      final obj = jsonDecode(raw);
      if (obj is Map<String, dynamic>) value = obj;
    } catch (_) {}
    return (response.statusCode, value, raw);
  } finally {
    client.close(force: true);
  }
}

String _text(Map<String, dynamic>? value, ModelProtocol protocol) {
  if (value == null) return '';
  if (protocol == ModelProtocol.messages) {
    final c = value['content'];
    return c is List
        ? c
              .whereType<Map>()
              .where((b) => b['type'] == 'text')
              .map((b) => b['text'] ?? '')
              .join()
        : '';
  }
  final choices = value['choices'];
  return choices is List && choices.isNotEmpty
      ? '${choices.first['message']['content'] ?? ''}'
      : '';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('LoongPass 模型接入验收中'))),
    ),
  );
  const reportPath = String.fromEnvironment('MODEL_POOLING_REPORT');
  const clientScript = String.fromEnvironment('MODEL_POOLING_CLAUDE_SCRIPT');
  const onlySource = String.fromEnvironment('MODEL_POOLING_SOURCE');
  const pooled = bool.fromEnvironment('MODEL_POOLING_POOLED');
  const modelSelection = String.fromEnvironment('MODEL_POOLING_MODELS');
  const infer = bool.fromEnvironment(
    'MODEL_POOLING_INFERENCE',
    defaultValue: false,
  );
  if (reportPath.isEmpty || !File(reportPath).isAbsolute) {
    exit(2);
  }
  final initialOutput = File(reportPath);
  final output = await initialOutput.exists()
      ? File('$reportPath.restart.json')
      : initialOutput;
  await output.parent.create(recursive: true);
  await Process.run('/bin/chmod', ['700', output.parent.path]);
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'time': DateTime.now().toUtc().toIso8601String(),
    'real_inference_requested': infer,
    'sources': <Map<String, dynamic>>[],
  };
  final calls = <Map<String, dynamic>>[];
  report['dispatches'] = calls;
  final afterClient = <Future<void> Function()>[];
  final minimax = openNativeMiniMaxAccounts(region: 'cn');
  final rewardHttp = {
    for (final p in rewardProviders) p.id: RewardHttp(p.hosts),
  };
  final rewards = RewardAccounts(
    store: NativeAccountDocumentStore('RewardChannels'),
    providers: rewardProviders,
    transportFor: (p) => rewardHttp[p.id]!,
  );
  final workStore = WorkBuddyVaultFlutter(),
      workVault = WorkBuddyVault(WorkBuddyVaultFlutter());
  final work = WorkBuddyAccounts(create: createWorkBuddyMemoryOwner);
  final diagnostics = <Map<String, dynamic>>[];
  report['discovery_diagnostics'] = diagnostics;
  final workModels = _ObservedModels(diagnostics),
      zcodeHttp = _ObservedZcode(diagnostics);
  final qoder = createQoderDeviceAccounts(region: QoderRegion.cn),
      zcode = ZcodeActivityAccounts(
        store: NativeAccountDocumentStore('ZCode'),
        api: ZcodeApi(zcodeHttp),
        requestVerification: verifyNativeZcodeClaim,
      );
  final settings = _Settings(File('${output.parent.path}/local-settings.json'));
  final service = ModelService(store: settings, port: 0);
  try {
    try {
      await rewards.restore();
    } catch (_) {
      report['reward_restore'] = 'unavailable';
    }
    await work.restoreSaved(workVault, workStore.savedKeys);
    final prompt =
        jsonDecode(
              await rootBundle.loadString(
                'assets/protocols/zcode_start_prompt.json',
              ),
            )
            as Map<String, dynamic>;
    final sources = <ModelProvider>[
      MiniMaxModelProvider(minimax, 'cn'),
      LoomyModelProvider(rewards),
      WorkBuddyModelProvider(
        work,
        transport: workModels,
        clientVersion: WorkBuddyDesktopFlutter.clientVersion,
      ),
      QoderModelProvider(qoder),
      ZcodeModelProvider(
        zcode,
        prompt: prompt,
        transport: _ObservedModels(diagnostics),
      ),
    ].map((source) => _ObservedProvider(source, calls)).toList();
    for (final source in sources) {
      service.register(source);
    }
    final old = await settings.read();
    await service.load();
    report['restored_running'] = old.data['enabled'] == true && service.running;
    var extraAccountSelected = false;
    final clientSources = <Map<String, dynamic>>[];
    for (final source in sources) {
      if (onlySource.isNotEmpty && source.id != onlySource) continue;
      final row = <String, dynamic>{
        'source': source.id,
        'accounts': <Map<String, dynamic>>[],
      };
      (report['sources'] as List).add(row);
      List<ModelAccount> accounts;
      try {
        accounts = await source.accounts();
        row['saved_accounts'] = accounts.length;
      } catch (_) {
        row['status'] = 'account_store_unavailable';
        continue;
      }
      var index = 0;
      final take = pooled
          ? 8
          : !extraAccountSelected && accounts.length > 1
          ? 2
          : 1;
      var configured = 0;
      final nativeBindings = <Map<String, dynamic>>[];
      for (final account in accounts.take(8)) {
        if (configured >= take) break;
        final result = <String, dynamic>{'alias': '${source.id}-${++index}'};
        source.aliases[account.id] = result['alias'];
        (row['accounts'] as List).add(result);
        workModels.alias = result['alias'];
        zcodeHttp.alias = result['alias'];
        if (!infer) {
          result['status'] = 'inventory_only';
          continue;
        }
        try {
          final binding = await service.addAccount(
            providerId: source.id,
            accountId: account.id,
          );
          configured++;
          if (configured == 2) extraAccountSelected = true;
          result['catalog'] = 'passed';
          result['model_count'] = binding.models.length;
          result['native_models'] = [
            for (final m in binding.models) m.toJson(source.id),
          ];
          result['caller_key_fingerprint'] = sha256
              .convert(utf8.encode(binding.key))
              .toString()
              .substring(0, 16);
          final model = binding.models.where((m) => m.tools != false).first;
          result['model'] = model.id;
          result['protocol'] = model.protocol.name;
          nativeBindings.add({
            'key': binding.key,
            'model': model.id,
            'protocol': model.protocol.name,
          });
          await service.start();
          Future<Map<String, dynamic>> balance() async {
            try {
              switch (source.id) {
                case 'minimax-cn':
                  await minimax.refreshCredits(account.id);
                  return {
                    'unit': 'points',
                    ..._credits(minimax.credits(account.id)),
                  };
                case 'loomy':
                  await rewards.refreshCredits('loomy', account.id);
                  return {
                    'unit': 'points',
                    ..._credits(
                      rewards
                          .accountsFor('loomy')
                          .firstWhere((a) => a.identity == account.id)
                          .credits,
                    ),
                  };
                case 'workbuddy-cn':
                  final a = work.accounts.firstWhere(
                    (a) => a.stableId == account.id,
                  );
                  await work.refreshBalance(a.id);
                  return {'unit': 'credits', ..._credits(a.credits)};
                case 'qoder-cn':
                  await qoder.refreshCredits(account.id);
                  final c = qoder.credits(account.id)!;
                  return {
                    'unit': 'credits',
                    'plan_remaining': c.planRemaining,
                    'addon_remaining': c.addOnRemaining,
                    'packages': _credits(c.packages),
                  };
                case 'zcode-bigmodel':
                  await zcode.withInferenceAuthorization(
                    account.id,
                    (authorization) => authorization.balance(),
                  );
                  return {
                    'buckets': [
                      for (final b
                          in (await zcode.accounts())
                              .firstWhere((a) => a.id == account.id)
                              .buckets)
                        b.toJson(),
                    ],
                  };
              }
            } catch (_) {}
            return {'status': 'unknown'};
          }

          if (clientScript.isNotEmpty || pooled) {
            result['before'] = await balance();
            afterClient.add(() async {
              result['after'] = await balance();
            });
            result['status'] = 'prepared_for_claude';
            continue;
          }
          result['before'] = await balance();
          final body = <String, dynamic>{
            'model': model.id,
            'max_tokens': 128,
            'messages': [
              {'role': 'user', 'content': 'Reply with exactly LOONGPASS_OK.'},
            ],
          };
          final text = await _call(service, binding, model, body);
          result['text_http'] = text.$1;
          result['text'] =
              text.$1 == 200 &&
                  _text(text.$2, model.protocol).contains('LOONGPASS_OK')
              ? 'passed'
              : 'failed';
          if (result['text'] != 'passed') {
            result['status'] = 'text_failed';
            continue;
          }
          final streamed = await _call(service, binding, model, {
            ...body,
            'stream': true,
          });
          result['stream'] =
              streamed.$1 == 200 &&
                  (model.protocol == ModelProtocol.messages
                      ? streamed.$3.contains('message_stop')
                      : streamed.$3.contains('[DONE]'))
              ? 'passed'
              : 'failed';
          const marker = 'LOONGPASS_TOOL_ECHO';
          final schema = {
            'type': 'object',
            'properties': {
              'marker': {'type': 'string'},
            },
            'required': ['marker'],
          };
          final tools = model.protocol == ModelProtocol.messages
              ? [
                  {
                    'name': 'loongpass_echo',
                    'description': 'Echo the provided marker exactly.',
                    'input_schema': schema,
                  },
                ]
              : [
                  {
                    'type': 'function',
                    'function': {
                      'name': 'loongpass_echo',
                      'description': 'Echo the provided marker exactly.',
                      'parameters': schema,
                    },
                  },
                ];
          final messages = <Map<String, dynamic>>[
            {
              'role': 'user',
              'content':
                  'Call loongpass_echo with marker $marker. After its result, repeat that result exactly.',
            },
          ];
          final toolBody = {
            ...body,
            'messages': messages,
            'tools': tools,
            'max_tokens': 256,
            'tool_choice': model.protocol == ModelProtocol.messages
                ? {'type': 'tool', 'name': 'loongpass_echo'}
                : {
                    'type': 'function',
                    'function': {'name': 'loongpass_echo'},
                  },
          };
          final call = await _call(service, binding, model, toolBody);
          result['tool_http'] = call.$1;
          var paired = false;
          if (call.$1 == 200 && call.$2 != null) {
            if (model.protocol == ModelProtocol.messages) {
              final c = call.$2!['content'];
              final tc = c is List
                  ? c
                        .whereType<Map>()
                        .where(
                          (v) =>
                              v['type'] == 'tool_use' &&
                              v['name'] == 'loongpass_echo',
                        )
                        .firstOrNull
                  : null;
              if (tc != null && tc['input']?['marker'] == marker) {
                messages.add({'role': 'assistant', 'content': c});
                messages.add({
                  'role': 'user',
                  'content': [
                    {
                      'type': 'tool_result',
                      'tool_use_id': tc['id'],
                      'content': marker,
                    },
                  ],
                });
                paired = true;
              }
            } else {
              final choices = call.$2!['choices'];
              final msg = choices is List && choices.isNotEmpty
                  ? choices.first['message']
                  : null;
              final t = msg is Map ? msg['tool_calls'] : null;
              final tc = t is List && t.isNotEmpty ? t.first : null;
              if (tc is Map &&
                  tc['function']?['name'] == 'loongpass_echo' &&
                  jsonDecode(tc['function']['arguments'])['marker'] == marker) {
                messages.add(Map<String, dynamic>.from(msg));
                messages.add({
                  'role': 'tool',
                  'tool_call_id': tc['id'],
                  'content': marker,
                });
                paired = true;
              }
            }
          }
          if (paired) {
            final follow = await _call(service, binding, model, {
              ...body,
              'max_tokens': 256,
              'messages': messages,
              'tools': tools,
            });
            result['tool_loop'] =
                follow.$1 == 200 &&
                    _text(follow.$2, model.protocol).contains(marker)
                ? 'passed'
                : 'failed';
          } else {
            result['tool_loop'] = 'no_matching_tool_call';
          }
          result['after'] = await balance();
          result['status'] = 'tested';
        } catch (failure) {
          result['failure'] = _failure(failure);
          result['status'] = 'unavailable_or_incomplete';
        }
      }
      if (!pooled && nativeBindings.isNotEmpty)
        clientSources.add({
          'id': source.id,
          'protocols': source.protocols.map((p) => p.name).toList(),
          'bindings': nativeBindings,
        });
      await output.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
        flush: true,
      );
    }
    if (pooled) {
      report['routed_catalog'] = [
        for (final m in service.pooledModels) m.toJson(),
      ];
      final requested = modelSelection
          .split(',')
          .where((m) => m.isNotEmpty)
          .toSet();
      report['missing_requested_models'] = requested
          .difference(service.pooledModels.map((m) => m.id).toSet())
          .toList();
      for (final model in service.pooledModels.where(
        (m) => requested.contains(m.id),
      )) {
        clientSources.add({
          'id': model.id.replaceAll(RegExp(r'[^a-z0-9-]'), '-'),
          'protocols': ['messages'],
          'bindings': [
            {'key': service.pooledKey, 'model': model.id},
          ],
        });
      }
    }
    if (clientScript.isNotEmpty && clientSources.isNotEmpty) {
      final process = await Process.start('python3', ['-I', clientScript]);
      process.stdin.write(
        jsonEncode({
          'origin': service.endpoint.toString(),
          'sources': clientSources,
          'unified': pooled,
        }),
      );
      await process.stdin.close();
      final stdoutText = process.stdout.transform(utf8.decoder).join();
      final stderrDone = process.stderr.drain<void>();
      await process.exitCode;
      await stderrDone;
      try {
        report['claude_code'] = jsonDecode(await stdoutText);
      } catch (_) {
        report['claude_code'] = {'status': 'client_integration_unavailable'};
      }
    }
    for (final observe in afterClient) {
      await observe();
    }
    report['binding_fingerprints'] = [
      for (final b in service.bindings)
        {
          'source': b.providerId,
          'grant': sha256
              .convert(utf8.encode(b.key))
              .toString()
              .substring(0, 16),
        },
    ];
  } catch (_) {
    report['status'] = 'acceptance_incomplete';
  } finally {
    await service.dispose();
    minimax.dispose();
    rewards.dispose();
    for (final h in rewardHttp.values) {
      h.close();
    }
    work.close();
    workVault.close();
    qoder.dispose();
    zcode.dispose();
    await output.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      flush: true,
    );
    await Process.run('/bin/chmod', ['600', output.path]);
  }
  exit(0);
}
