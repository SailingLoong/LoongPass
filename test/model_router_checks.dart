import '../lib/model_provider.dart';
import '../lib/model_router.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

ModelTarget target(String binding, String provider, String model) =>
    ModelTarget(
      bindingId: binding,
      providerId: provider,
      model: ModelDefinition(
        model,
        protocol: ModelProtocol.chat,
        tools: true,
        canonicalId: model == 'auto' ? null : model,
      ),
    );

void main() {
  const capable = ModelDefinition(
    'exact-model',
    protocol: ModelProtocol.chat,
    images: true,
    reasoning: true,
    alwaysThinks: true,
    reasoningEfforts: ['low', 'high'],
    defaultReasoningEffort: 'high',
  );
  final facts = capable.toJson('source');
  check(
    (facts['modalities'] as Map)['input'].join(',') == 'text,image' &&
        (facts['supported_reasoning_levels'] as List).join(',') == 'low,high' &&
        facts['supports_thinking_type'] == 'only' &&
        (facts['think_efforts'] as Map)['default_effort'] == 'high',
    'model capabilities must use the fields Magpie actually consumes',
  );
  final a = target('a', 'loomy', 'GLM-5.3-Flash');
  final b = target('b', 'zcode-bigmodel', 'glm-5.3-flash');
  final c = target('c', 'loomy', 'GLM-5.3');
  final groups = groupModelTargets([
    a,
    b,
    c,
    target('d', 'first', 'auto'),
    target('e', 'second', 'auto'),
    target('f', 'first', 'DeepSeek-V4-Flash-0731'),
    target('g', 'second', 'DeepSeek-V4-Flash'),
  ]);
  check(groups.length == 6, 'model versions or source aliases conflated');
  final shared = groups.singleWhere((m) => m.id == 'glm-5.3-flash');
  check(shared.targets.length == 2, 'same model did not pool across sources');
  check(
    shared.platformCount == 2 && shared.accountCount == 2,
    'source counts are not owned by the routed model',
  );
  check(groups.any((m) => m.id == 'first/auto'), 'source alias not namespaced');
  check(
    groups.any((m) => m.id == 'deepseek-v4-flash-0731'),
    'dated model lost',
  );
  final future = groupModelTargets([
    target('future-a', 'first', 'new-family-12.3'),
    target('future-b', 'second', 'New-Family-12.3'),
    const ModelTarget(
      bindingId: 'opaque-a',
      providerId: 'first',
      model: ModelDefinition('lane-42', protocol: ModelProtocol.chat),
    ),
    const ModelTarget(
      bindingId: 'opaque-b',
      providerId: 'second',
      model: ModelDefinition('lane-42', protocol: ModelProtocol.chat),
    ),
  ]);
  check(
    future.length == 3 &&
        future.singleWhere((m) => m.id == 'new-family-12.3').targets.length ==
            2,
    'router guessed identity or requires a model-family allowlist',
  );
  final versioned = groupModelTargets([
    const ModelTarget(
      bindingId: 'kimi',
      providerId: 'qoder-cn',
      model: ModelDefinition(
        'kmodel_latest',
        canonicalId: 'Kimi-K3.1-Pro',
        protocol: ModelProtocol.chat,
      ),
    ),
  ]).single;
  check(
    versioned.toJson()['name'] == 'Kimi-K3.1-Pro',
    'public catalog displayed an opaque routing handle as the model name',
  );

  var now = DateTime.utc(2026, 11, 8);
  final router = ModelRouter(now: () => now, maxSessions: 3);
  final pool = [a, b];
  final first = router.select(shared.id, pool, session: 'caller-a/session-1');
  final next = router.select(shared.id, pool, session: 'caller-a/session-2');
  check(first.id != next.id, 'new sessions did not distribute');
  for (var i = 0; i < 8; i++) {
    check(
      router.select(shared.id, pool, session: 'caller-a/session-1').id ==
          first.id,
      'session moved between healthy accounts',
    );
  }
  router.failed(first);
  final replacement = router.select(
    shared.id,
    pool,
    session: 'caller-a/session-1',
  );
  check(replacement.id != first.id, 'failed target reused by next request');
  now = now.add(const Duration(minutes: 2));
  check(
    router.select(shared.id, pool, session: 'caller-a/session-1').id ==
        replacement.id,
    'recovered account stole an established session',
  );
  check(
    router.select(shared.id, [first], session: 'caller-a/session-1').id ==
        first.id,
    'removed target remained pinned',
  );

  router.failed(a);
  router.failed(b);
  try {
    router.select(shared.id, pool, session: 'no-target');
    throw StateError('all failed targets admitted');
  } on ModelServiceFailure catch (e) {
    check(e.code == 'model_temporarily_unavailable', 'wrong exhaustion error');
  }
  now = now.add(const Duration(minutes: 2));
  for (var i = 0; i < 6; i++) {
    router.select(shared.id, pool, session: 'private-session-$i');
  }
  check(router.sessionCount == 3, 'affinity state grew without a bound');
  now = now.add(const Duration(hours: 7));
  router.select(shared.id, pool, session: 'new');
  check(router.sessionCount == 1, 'idle affinity records retained');
  final one = router.select(shared.id, pool);
  final two = router.select(shared.id, pool);
  check(one.id != two.id, 'requests without sessions all glued together');
  check(router.sessionCount == 1, 'requests without sessions created affinity');
  print(
    'PASS exact model identity, cross-platform sessions, cooldown and bounded affinity',
  );
}
