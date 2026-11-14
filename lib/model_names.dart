/// Official API IDs are the stable keys of the model view. Channel IDs remain
/// on each binding and are the only IDs sent to the supplier host.
/// Sources checked 2026-11-15:
/// api-docs.deepseek.com/quick_start/pricing/
/// platform.minimax.io/docs/api-reference/text-anthropic-api
/// docs.bigmodel.cn/cn/guide/models/vlm/glm-5.3-flash
/// help.aliyun.com/zh/model-studio/newly-released-models
/// platform.kimi.com/docs/models
/// platform.claude.com/docs/en/about-claude/model-deprecations
/// developers.openai.com/api/docs/models/all
/// aistudio.google.com/docs/models
const _officialModels = [
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
final _officialByKey = {for (final id in _officialModels) _key(id): id};

// IDs documented by the pinned supplier packages. They are scoped because a
// provider's opaque alias says nothing about an identically named other one.
const _channelAliases = {
  'qoder': {
    'dfmodel': 'deepseek-flash',
    'dmodel': 'deepseek-v4-pro',
    'qmodel_38max': 'qwen3.8-max',
    'qfmodel': 'qwen3.8-flash',
    'qmodel_latest': 'qwen3.7-max',
    'qmodel': 'qwen3.7-plus',
  },
};
const _deepseekFlashAliases = {
  'deepseek-v4-flash',
  'deepseek-v4.1-flash',
  'deepseek-v4-flash-0731',
  'deepseek-v4.1-flash-1017',
  'deepseek-v4-flash-1017',
  'deepseek-v4-1-flash-261017',
  'deepseek-v4-flash-vision-exp',
};

String? officialModelId(String provider, Map<String, dynamic> model) {
  final native = (model['id'] as String? ?? '').toLowerCase();
  final channel = _channelAliases[provider]?[native];
  if (channel != null) return channel;
  var id = native;
  if (provider == 'zcode') id = id.replaceFirst(RegExp(r'-trial$'), '');
  if (provider == 'workbuddy') id = id.replaceFirst(RegExp(r'-sg$'), '');
  // TRAE's -max and WorkBuddy's -1m are source context modes. The
  // unmodified binding retains their limits and supplier API identity.
  if (provider == 'trae' && id.endsWith('-max')) {
    final base = officialModelId(provider, {
      'id': id.substring(0, id.length - 4),
    });
    if (base != null) return base;
  }
  if (provider == 'workbuddy' && id.endsWith('-1m'))
    id = id.substring(0, id.length - 3);
  if (_deepseekFlashAliases.contains(id)) return 'deepseek-flash';
  if (id == 'deepseek-v4-pro-0813') return 'deepseek-v4-pro';
  const aliases = {
    'claude-opus-4-5-20251101': 'claude-opus-4-5',
    'claude-sonnet-4-5-20250929': 'claude-sonnet-4-5',
    'claude-haiku-4-5-20251001': 'claude-haiku-4-5',
    'gemini-3.1-pro': 'gemini-3.1-pro-preview',
    'gemini-3-pro': 'gemini-3-pro-preview',
    'gemini-3-flash': 'gemini-3-flash-preview',
  };
  final exact = aliases[id] ?? _officialByKey[_key(id)];
  if (exact != null) return exact;
  // Only a complete, known name is accepted. Dates and arbitrary suffixes
  // cannot silently turn an unknown model into a known model.
  final name = model['name'];
  return name is String ? _officialByKey[_key(name)] : null;
}
