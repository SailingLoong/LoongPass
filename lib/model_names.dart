/// Official API IDs are the stable keys of the model view. Channel IDs remain
/// on each binding and are the only IDs sent to the supplier host.
/// Sources checked 2026-11-15:
/// api-docs.deepseek.com/quick_start/pricing/
/// platform.minimax.io/docs/api-reference/text-anthropic-api
/// platform.minimax.io/docs/release-notes/models
/// docs.bigmodel.cn/cn/guide/models/vlm/glm-5.3-flash
/// docs.bigmodel.cn/cn/guide/models/text/glm-5.1 (checked 2026-11-16)
/// docs.bigmodel.cn/cn/guide/models/text/glm-5
/// docs.bigmodel.cn/cn/guide/models/text/glm-4.7
/// docs.bigmodel.cn/cn/guide/models/text/glm-4.6
/// help.aliyun.com/zh/model-studio/newly-released-models
/// platform.kimi.com/docs/models
/// platform.claude.com/docs/en/about-claude/model-deprecations
/// developers.openai.com/api/docs/models/all
/// aistudio.google.com/docs/models
const _originalOfficialModels = [
  'deepseek-flash',
  'deepseek-v4-pro',
  'claude-fable-5-2',
  'claude-fable-5-1',
  'claude-fable-5',
  'claude-mythos-5-2',
  'claude-mythos-5-1',
  'claude-mythos-5',
  'claude-opus-5-5',
  'claude-opus-5',
  'claude-opus-4-8',
  'claude-opus-4-7',
  'claude-opus-4-6',
  'claude-opus-4-5',
  'claude-sonnet-5-5',
  'claude-sonnet-5',
  'claude-sonnet-4-6',
  'claude-sonnet-4-5',
  'claude-haiku-5-5',
  'claude-haiku-4-5',
  'gpt-6.1-sol',
  'gpt-6.1-terra',
  'gpt-6-astra',
  'gpt-6-sol',
  'gpt-6-luna',
  'gpt-5.6-sol',
  'gpt-5.6-terra',
  'gpt-5.6-luna',
  'gpt-5.5',
  'gpt-5.5-pro',
  'gpt-5.4',
  'gpt-5.4-pro',
  'gpt-5.4-mini',
  'gpt-5.4-nano',
  'gpt-5.3-codex',
  'gpt-5.3-codex-spark',
  'gpt-5.2',
  'gpt-5.2-codex',
  'gpt-5.1',
  'gpt-5.1-codex',
  'gpt-5.1-codex-max',
  'gpt-5.1-codex-mini',
  'gpt-5',
  'gpt-5-mini',
  'gpt-5-nano',
  'gpt-4.1',
  'gpt-4.1-mini',
  'gpt-4.1-nano',
  'gpt-4o',
  'gpt-4o-mini',
  'o3',
  'o3-mini',
  'o4-mini',
  'gemini-4-carbon',
  'gemini-4-argon',
  'gemini-4-hydrogen',
  'gemini-3.8-flash',
  'gemini-3.6-flash',
  'gemini-3.5-flash',
  'gemini-3.5-flash-lite',
  'gemini-3.1-pro-preview',
  'gemini-3.1-flash-lite',
  'gemini-3-flash-preview',
  'gemini-3-pro-preview',
  'gemini-2.5-pro',
  'gemini-2.5-flash',
  'gemini-2.5-flash-lite',
  'MiniMax-M3',
  'MiniMax-M3.1-Flash',
  'MiniMax-M2.7',
  'MiniMax-M2.7-highspeed',
  'MiniMax-M2.5',
  'MiniMax-M2.5-highspeed',
  'MiniMax-M2.1',
  'MiniMax-M2',
  'kimi-k3',
  'kimi-k3.1-pro',
  'kimi-k3.1-pro-highspeed',
  'kimi-k2.7-code',
  'kimi-k2.7-code-highspeed',
  'kimi-k2.6',
  'kimi-k2.5',
  'glm-5.3',
  'glm-5.3-flash',
  'glm-5.3-flashx',
  'glm-5.3-flashx-legal',
  'glm-5.2',
  'glm-5-turbo',
  'qwen3.8-max',
  'qwen3.8-flash',
  'qwen3.7-max',
  'qwen3.7-plus',
  'qwen3.7-flash',
  'qwen3.6-plus',
  'qwen3.5-plus',
];

String _key(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
// Freeze the inventories used to key the two previous routing formats.
final _legacyOfficialByKey = {
  for (final id in _originalOfficialModels) _key(id): id,
};
final _previousOfficialByKey = {
  ..._legacyOfficialByKey,
  for (final id in ['glm-5.1', 'glm-5', 'glm-4.7', 'glm-4.6']) _key(id): id,
};

// Additional model IDs verified against the model publishers' API docs.
// Qwen: help.aliyun.com/zh/model-studio/qwen4-max (and qwen4-max-preview)
// Tencent: cloud.tencent.com/document/product/1823/130051
// Kimi: kimi.com/code/docs/en/kimi-code/models.html and K2 0905 launch notes
// Xiaomi: mimo.xiaomi.com/blog/mimo-v2-6-tool-call-repetition
// StepFun: platform.stepfun.com/cookbook/step-5-tool-calling
// Spark: xfyun.cn/doc/spark/Spark-X2.5.html
// Ark: console.volcengine.com/ark/region:cn-beijing/docs/coding-plan-personal-model-release
final _officialByKey = {
  ..._previousOfficialByKey,
  for (final id in [
    'doubao-seed-evolving',
    'doubao-seed-2.1-pro',
    'doubao-seed-2.1-turbo',
    'doubao-seed-2.0-code',
    'doubao-seed-code',
    'glm-5v-turbo',
    'hy3',
    'hy4',
    'hy4-flash',
    'hy4-preview',
    'kimi-for-coding',
    'kimi-k2-0905-preview',
    'mimo-v2.5',
    'mimo-v2.6-flash',
    'mimo-v2.6-pro',
    'qwen3-coder-next',
    'qwen4-max',
    'qwen4-max-preview',
    'spark-x2.5',
    'step-5-preview',
  ])
    _key(id): id,
};

// IDs documented by the pinned supplier packages. They are scoped because a
// provider's opaque alias says nothing about an identically named other one.
const _previousQoderAliases = {
  'dfmodel': 'deepseek-flash',
  'dmodel': 'deepseek-v4-pro',
  'qmodel_38max': 'qwen3.8-max',
  'qfmodel': 'qwen3.8-flash',
  'qmodel_latest': 'qwen3.7-max',
  'qmodel': 'qwen3.7-plus',
};
const _deepseekFlashAliases = {
  'deepseek-v4-flash',
  'deepseek-v4.1-flash',
  'deepseek-v4-flash-0731',
  'deepseek-v4.1-flash-1017',
  'deepseek-v4-flash-1017',
  'deepseek-v4-1-flash-261017',
  'deepseek-v4-flash-vision-exp',
  'deepseek-flash-1017',
};

const _previousAliases = {
  'deepseek-v4-pro-0813': 'deepseek-v4-pro',
  'minimax-m3.1-flash-preview': 'MiniMax-M3.1-Flash',
  'qwen3.8-max-0902': 'qwen3.8-max',
  'qwen3.8-max-2026-09-02': 'qwen3.8-max',
  'claude-opus-4-5-20251101': 'claude-opus-4-5',
  'claude-sonnet-4-5-20250929': 'claude-sonnet-4-5',
  'claude-haiku-4-5-20251001': 'claude-haiku-4-5',
  'gemini-3.1-pro': 'gemini-3.1-pro-preview',
  'gemini-3-pro': 'gemini-3-pro-preview',
  'gemini-3-flash': 'gemini-3-flash-preview',
};

// Match whole names after normalizing presentation and verified aliases.
final _officialAliasesByKey = {
  for (final alias in _deepseekFlashAliases) _key(alias): 'deepseek-flash',
  for (final entry in _previousAliases.entries) _key(entry.key): entry.value,
  _key('kimi-k2-0905'): 'kimi-k2-0905-preview',
  _key('kimi-k2.8-preview'): 'kimi-for-coding',
  _key('qwen4.0-max-preview'): 'qwen4-max-preview',
};

String? _officialName(String value) {
  final key = _key(value);
  return _officialAliasesByKey[key] ?? _officialByKey[key];
}

String _withoutTraeMode(String id) =>
    id.replaceFirst(RegExp(r'(?:-auto)?-max$|-auto$'), '');

String? _traeModel(String id, String name) {
  final label = name.replaceFirst(RegExp(r'\s+\(max\)$'), '');
  final base = _withoutTraeMode(id);
  // TRAE can reuse a Seed config name while changing the advertised model.
  if (id.startsWith('doubao-') || id == 'doubao_1_6') {
    final seed = label.startsWith('seed-') ? 'doubao-$label' : label;
    final official = switch (seed) {
      'doubao-seed-2.1-pro-0915' => 'doubao-seed-2.1-pro',
      _ => _officialName(seed),
    };
    if (official != null) return official;
  }
  return _officialName(id) ??
      switch (base) {
        'deepseek-v4-flash-official' => 'deepseek-flash',
        'deepseek-v4-pro-official' => 'deepseek-v4-pro',
        _ => _officialName(base) ?? _officialName(label),
      };
}

String? officialModelId(String provider, Map<String, dynamic> model) {
  final channel = provider.replaceFirst(RegExp(r'-(cn|global)$'), '');
  final id = (model['id'] as String? ?? '').trim().toLowerCase().replaceFirst(
    RegExp(r'@\d+[km]$'),
    '',
  );
  final name = (model['name'] as String? ?? '').trim().toLowerCase();
  return switch (channel) {
    'trae' => _traeModel(id, name),
    // Live labels identify the current model. The rolling Qwen slot has
    // already served distinct model generations under the same native ID.
    'qoder' =>
      _officialName(id) ??
          _officialName(name) ??
          (id != 'qmodel_latest' && (name.isEmpty || name == id)
              ? _previousQoderAliases[id]
              : null),
    'workbuddy' => switch (id.replaceFirst(RegExp(r'-sg$'), '')) {
      'hy4std' => 'hy4',
      'hy4flash-free' => 'hy4-flash',
      final base =>
        _officialName(base.replaceFirst(RegExp(r'-1m$'), '')) ??
            _officialName(name),
    },
    'zcode' =>
      _officialName(id.replaceFirst(RegExp(r'-trial$'), '')) ??
          _officialName(name),
    'loomy' => _officialName(id) ?? _officialName(name.split(' (').first),
    _ => _officialName(id) ?? _officialName(name),
  };
}

/// Old v2 fallback keys were derived from display names. Recover an official
/// identity for an old preference even when that source is temporarily absent.
String? officialModelIdForPreviousKey(String id) =>
    _officialName(id.replaceFirst(RegExp(r'-\(max\)$'), ''));

String legacyModelId(String provider, Map<String, dynamic> model) =>
    _previousOfficialModelId(provider, model, legacy: true) ??
    '$provider/${model['id']}';

String previousModelId(String provider, Map<String, dynamic> model) =>
    _previousOfficialModelId(provider, model, legacy: false) ??
    unverifiedModelId(model);

String? _previousOfficialModelId(
  String provider,
  Map<String, dynamic> model, {
  required bool legacy,
}) {
  if (!legacy) provider = provider.replaceFirst(RegExp(r'-(cn|global)$'), '');
  final names = legacy ? _legacyOfficialByKey : _previousOfficialByKey;
  final native = (model['id'] as String? ?? '').toLowerCase();
  final channel = provider == 'qoder' ? _previousQoderAliases[native] : null;
  if (channel != null) return channel;
  var id = native;
  if (provider == 'zcode') id = id.replaceFirst(RegExp(r'-trial$'), '');
  if (provider == 'workbuddy') id = id.replaceFirst(RegExp(r'-sg$'), '');
  // TRAE's -max and WorkBuddy's -1m are source context modes. The
  // unmodified binding retains their limits and supplier API identity.
  if (provider == 'trae' && id.endsWith('-max')) {
    final base = _previousOfficialModelId(provider, {
      'id': id.substring(0, id.length - 4),
    }, legacy: legacy);
    if (base != null) return base;
  }
  if (provider == 'workbuddy' && id.endsWith('-1m'))
    id = id.substring(0, id.length - 3);
  if (_deepseekFlashAliases.contains(id)) return 'deepseek-flash';
  final exact = _previousAliases[id] ?? names[_key(id)];
  if (exact != null) return exact;
  // Only a complete, known name is accepted. Dates and arbitrary suffixes
  // cannot silently turn an unknown model into a known model.
  final name = model['name'];
  return name is String ? names[_key(name)] : null;
}

/// A supplier's complete display name groups its accounts even when the
/// underlying official API model has not been identified. Native IDs remain
/// on the bindings, and this fallback never claims an official model mapping.
String unverifiedModelId(Map<String, dynamic> model) {
  final name = (model['name'] as String? ?? '').trim();
  final id = Uri.encodeComponent(
    (name.isEmpty ? model['id'] as String : name)
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '-'),
  );
  return id == 'auto' ? 'model-auto' : id;
}
