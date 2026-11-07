// Native Start Plan contract and request layout adapted from
// magpie-community/plugins packages/zcode 0.1.56 (MIT). The protocol prompt
// asset is the same pinned client's required public format; caller system
// instructions and tools are retained. Never routes to a paid Coding Plan.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'account_registration.dart';
import 'model_provider.dart';
import 'model_http.dart';
import 'model_sse.dart';
import 'zcode_api.dart';
import 'zcode_activity_accounts.dart';

class ZcodeModelProvider extends ModelProvider {
  final ZcodeActivityAccounts owner;
  final Map<String, dynamic> prompt;
  final ModelTransport transport;
  final _models = <String, (String, List<ModelDefinition>)>{};
  ZcodeModelProvider(
    this.owner, {
    required this.prompt,
    ModelTransport? transport,
  }) : transport = transport ?? ModelHttp();
  @override
  String get id => 'zcode-bigmodel';
  @override
  String get name => 'ZCode BigModel · 赠送套餐';
  @override
  Set<ModelProtocol> get protocols => {ModelProtocol.messages};
  @override
  Stream<void> get changes => owner.authorizationChanges;
  @override
  Future<List<ModelAccount>> accounts() async => [
    for (final a in await owner.accounts())
      if (a.family == 'bigmodel')
        ModelAccount(a.id, a.label, registrationId: a.registrationId),
  ];
  static num? _number(Object? value) {
    final n = value is num ? value : num.tryParse('$value');
    return n != null && n.isFinite && n >= 0 ? n : null;
  }

  static Set<String> _entitled(Map<String, dynamic> raw) {
    final b = zcodeData(raw);
    final now = _number(b['server_time']);
    if (now == null || b['plans'] is! List || b['balances'] is! List)
      throw const ModelServiceFailure('invalid_entitlement');
    final plans = (b['plans'] as List)
        .whereType<Map>()
        .where(
          (p) =>
              p['status'] == 'active' &&
              (_number(p['starts_at']) == null ||
                  _number(p['starts_at'])! <= now) &&
              (_number(p['ends_at']) == null || _number(p['ends_at'])! > now),
        )
        .toList();
    final out = <String>{};
    for (final bucket in b['balances']) {
      if (bucket is! Map) continue;
      if (!plans.any(
        (p) => p['user_plan_id'] != null && bucket['user_plan_id'] != null
            ? p['user_plan_id'] == bucket['user_plan_id']
            : p['plan_id'] == bucket['plan_id'],
      ))
        continue;
      if (_number(bucket['expires_at']) != null &&
          _number(bucket['expires_at'])! <= now)
        continue;
      final left = _number(bucket['remaining_units']);
      final used = _number(bucket['used_units']),
          total = _number(bucket['total_units']);
      if (left == null && (used == null || total == null) ||
          left != null && left <= 0 ||
          left == null && used! >= total!)
        continue;
      if (bucket['capabilities'] is! List) continue;
      for (final capability in bucket['capabilities']) {
        if (capability is! String) continue;
        final c = capability.startsWith('model:')
            ? capability.substring(6)
            : capability.contains(':')
            ? ''
            : capability;
        if (c.trim().isNotEmpty) out.add(c.trim().toLowerCase());
      }
    }
    return out;
  }

  static List<ModelDefinition> _catalog(
    Map<String, dynamic> config,
    Set<String> allowed,
  ) {
    final c = config['config'];
    final canonical = <String, String>{};
    final off = <String>{};
    final providerRules = c is Map ? c['providerConfigRules'] : null;
    if (providerRules is Map && providerRules['providerRules'] is List)
      for (final r in providerRules['providerRules']) {
        if (r is! Map ||
            r['providerId'] != 'account:zai-start-plan' ||
            r['builtinModelIds'] is! List)
          continue;
        for (final id in r['builtinModelIds']) {
          if (id is String) canonical[id.toLowerCase()] = id;
        }
      }
    final rules = c is Map ? c['modelConfigRules'] : null;
    if (rules is Map && rules['builtinProviderModelRules'] is List)
      for (final r in rules['builtinProviderModelRules']) {
        if (r is! Map ||
            r['providerId'] != 'account:zai-start-plan' ||
            r['modelId'] is! String)
          continue;
        final id = r['modelId'] as String;
        canonical[id.toLowerCase()] = id;
        if (r['config'] is Map && r['config']['enabled'] == false)
          off.add(id.toLowerCase());
      }
    final result = <ModelDefinition>[];
    for (final key in allowed) {
      if (off.contains(key)) continue;
      final id = canonical[key] ?? key;
      int? context, output;
      if (rules is Map && rules['modelRules'] is List)
        for (final r in rules['modelRules']) {
          if (r is! Map || r['modelMatch'] is! String || r['config'] is! Map)
            continue;
          bool matches;
          try {
            matches = RegExp(
              '^(?:${r['modelMatch']})\$',
              caseSensitive: false,
            ).hasMatch(id);
          } catch (_) {
            continue;
          }
          if (!matches) continue;
          final row = r['config'];
          final properties = row['properties'], options = row['optionSpecs'];
          final cw = properties is Map ? properties['contextWindow'] : null;
          final limit = options is Map ? options['maxOutputTokens'] : null;
          final max = limit is Map ? limit['max'] : null;
          if (cw is int && cw > 0) context = cw;
          if (max is int && max > 0) output = max;
        }
      result.add(
        ModelDefinition(
          id,
          protocol: ModelProtocol.messages,
          contextWindow: context,
          outputLimit: output,
          tools: true,
        ),
      );
    }
    return result;
  }

  @override
  Future<ModelCatalog> discoverModels(
    String accountId,
  ) => owner.withInferenceAuthorization(accountId, (lease) async {
    final entitled = _entitled(await lease.balance());
    if (entitled.isEmpty) throw const ModelServiceFailure('gift_unavailable');
    final configs = zcodeData(await lease.clientConfig())['configs'];
    final url = configs is Map ? configs['builtin_provider_config_json'] : null;
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment)
      throw const ModelServiceFailure('model_discovery_failed');
    final config = await modelJson(
      transport,
      uri,
      headers: {'User-Agent': 'LoongPass'},
      isCurrent: lease.isCurrent,
    );
    final models = _catalog(config, entitled);
    if (models.isEmpty) throw const ModelServiceFailure('gift_unavailable');
    _models[accountId] = (lease.registrationId, models);
    return ModelCatalog(registrationId: lease.registrationId, models: models);
  });
  Map<String, dynamic> _request(
    Map<String, dynamic> body,
    ZcodeInferenceAuthorization lease,
    String session,
  ) {
    final version = lease.context['version']!
        .split(RegExp(r'[-+]'))
        .first
        .split('.')
        .map(int.parse)
        .toList();
    if (version[0] < 3 ||
        version[0] == 3 &&
            (version[1] < 17 || version[1] == 17 && version[2] < 2))
      throw const ModelServiceFailure('unsupported_client_version');
    final own = <String>[];
    final system = body['system'];
    if (system is String)
      own.add(system);
    else if (system is List)
      for (final block in system) {
        if (block is Map && block['type'] == 'text' && block['text'] is String)
          own.add(block['text']);
      }
    Map<String, dynamic> cached(String t) => {
      'type': 'text',
      'text': t,
      'cache_control': {'type': 'ephemeral'},
    };
    final tools = body['tools'];
    final skill =
        tools is List &&
        tools.whereType<Map>().any((t) => t['name'] == 'Skill');
    final dynamicText = [
      prompt['dynamicBehavior'],
      if (skill) prompt['sessionGuidance'],
      '${prompt['environment']['heading']}\n${prompt['environment']['invokedLine']}\n - ${prompt['environment']['platformLabel']}: ${lease.context['platform']}\n - ${prompt['environment']['osVersionLabel']}: ${Platform.operatingSystemVersion}',
      (prompt['poweredBy'] as String)
          .replaceAll('{provider}', 'bigmodel-api')
          .replaceAll('{model}', body['model']),
      prompt['contextManagement'],
      ...own,
    ].join('\n\n');
    final messages = (jsonDecode(jsonEncode(body['messages'])) as List)
        .cast<Map<String, dynamic>>();
    for (final m in messages) {
      if (m['content'] is List)
        for (final b in m['content']) {
          if (b is Map) b.remove('cache_control');
        }
    }
    if (messages.isNotEmpty) {
      final last = messages.last;
      final content = last['content'];
      if (content is String)
        last['content'] = [cached(content)];
      else if (content is List && content.isNotEmpty && content.last is Map)
        content.last['cache_control'] = {'type': 'ephemeral'};
    }
    final date = DateTime.now().toIso8601String().substring(0, 10);
    return {
      ...body,
      'system': [
        cached(prompt['cliPrefix']),
        cached((prompt['stableSections'] as List).join('\n\n')),
        cached('\n\n$dynamicText'),
      ],
      'messages': [
        {
          'role': 'user',
          'content': [
            {
              'type': 'text',
              'text':
                  '<system-reminder>${(prompt['context']['currentDateLine'] as String).replaceAll('{date}', date)}</system-reminder>',
            },
          ],
        },
        ...messages,
      ],
      if (tools is List)
        'tools': [
          for (final t in tools)
            if (t is Map)
              {
                for (final e in t.entries)
                  if (e.key != 'cache_control') e.key: e.value,
              },
        ],
      'metadata': {
        if (body['metadata'] is Map) ...body['metadata'] as Map,
        'user_id': jsonEncode({
          'device_id': lease.context['deviceMid'],
          'account_uuid': '',
          'session_id': session,
        }),
      },
    };
  }

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
    final saved = _models[accountId];
    final model = saved?.$2.where((m) => m.id == body['model']).firstOrNull;
    if (protocol != ModelProtocol.messages ||
        saved?.$1 != registrationId ||
        model == null)
      throw const ModelServiceFailure('model_not_available');
    await owner.withInferenceAuthorization(accountId, (lease) async {
      final allowed = _entitled(await lease.balance());
      if (!allowed.contains(model.id.toLowerCase()))
        throw const ModelServiceFailure('gift_exhausted');
      final first = (body['messages'] as List)
          .whereType<Map>()
          .where((m) => m['role'] == 'user')
          .firstOrNull;
      final session = sha256
          .convert(
            utf8.encode(jsonEncode([accountId, first?['content'] ?? ''])),
          )
          .toString()
          .substring(0, 32);
      final request = _request(body, lease, session);
      final ctx = lease.context;
      await transport.exchange(
        Uri.https('zcode.z.ai', '/api/v1/zcode-plan/anthropic/v1/messages'),
        method: 'POST',
        body: request,
        headers: {
          'Authorization': 'Bearer ${lease.token}',
          'Content-Type': 'application/json',
          'anthropic-version': '2023-06-01',
          'HTTP-Referer': 'https://zcode.z.ai',
          'User-Agent': 'ZCode/${ctx['version']}',
          'X-ZCode-App-Version': ctx['version']!,
          'X-Title': 'Z Code@electron',
          'X-Release-Channel': 'production',
          'X-Client-Language': ctx['language']!,
          'X-Client-Timezone': ctx['timezone']!,
          'X-ZCode-Agent': 'glm',
          'X-Platform': ctx['platform']!,
          'X-OS-Category': ctx['platform']!.startsWith('darwin')
              ? 'macos'
              : 'windows',
          'X-Device-Mid': ctx['deviceMid']!,
          'x-session-id': session,
          'x-request-id': newAccountRegistrationId(),
          'x-zcode-session-type': 'main',
          'x-zcode-trace-id': newAccountRegistrationId(),
          'x-zcode-query-source': 'main_turn',
        },
        isCurrent: () => lease.isCurrent() && isCurrent(),
        cancelled: cancelled,
        consume: (r) => _consume(r, consume),
      );
    }, expectedRegistrationId: registrationId);
  }

  static int? _businessError(Object? data) {
    if (data is! Map) return 502;
    final code = '${data['code'] ?? data['error']?['code'] ?? ''}';
    if ({'1005', '1113'}.contains(code)) return 429;
    if ({'401', '403'}.contains(code)) return 401;
    if (data['error'] != null ||
        data['type'] == 'error' ||
        code.isNotEmpty && !{'0', '200'}.contains(code))
      return 502;
    return null;
  }

  static Future<void> _consume(
    ModelReply upstream,
    Future<void> Function(ModelReply) consume,
  ) async {
    if (upstream.status != 200) {
      await consume(upstream);
      return;
    }
    if (!upstream.contentType.toLowerCase().contains('text/event-stream')) {
      final bytes = <int>[];
      await for (final part in upstream.body) {
        if (bytes.length + part.length > 4 * 1024 * 1024)
          throw const ModelServiceFailure('invalid_response');
        bytes.addAll(part);
      }
      dynamic data;
      try {
        data = jsonDecode(utf8.decode(bytes));
      } catch (_) {
        throw const ModelServiceFailure('invalid_response');
      }
      final status =
          _businessError(data) ??
          (data is Map && data['type'] == 'message' ? 200 : 502);
      await consume(
        ModelReply(
          status,
          'application/json',
          Stream.value(bytes),
          cancel: upstream.cancel,
        ),
      );
      return;
    }
    final iterator = StreamIterator(modelSseEvents(upstream.body));
    Map<String, dynamic> valueOf(ModelSseEvent event) {
      try {
        final value = jsonDecode(event.data);
        if (value is Map<String, dynamic>) return value;
      } catch (_) {}
      throw const ModelServiceFailure('invalid_response');
    }

    var recognized = false;
    try {
      while (await iterator.moveNext()) {
        final value = valueOf(iterator.current);
        final error = _businessError(value);
        if (error != null) {
          await consume(
            ModelReply(
              error,
              'application/json',
              const Stream.empty(),
              cancel: upstream.cancel,
            ),
          );
          return;
        }
        if (value['type'] == 'ping') continue;
        if (value['type'] == 'message_start') {
          recognized = true;
          break;
        }
        throw const ModelServiceFailure('invalid_response');
      }
      if (!recognized)
        throw const ModelServiceFailure('upstream_stream_incomplete');
      Stream<List<int>> replay() async* {
        do {
          final event = iterator.current;
          final value = valueOf(event);
          if (_businessError(value) != null)
            throw const ModelServiceFailure('upstream_stream_incomplete');
          yield event.encode();
          if (value['type'] == 'message_stop') return;
        } while (await iterator.moveNext());
        throw const ModelServiceFailure('upstream_stream_incomplete');
      }

      await consume(
        ModelReply(200, 'text/event-stream', replay(), cancel: upstream.cancel),
      );
    } finally {
      await iterator.cancel();
    }
  }
}
