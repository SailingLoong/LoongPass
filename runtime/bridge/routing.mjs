// Compatibility for existing client model aliases. Public discovery and all
// inference use native groups; this hook never chooses an account or refreshes.
export function onRequest(body, ctx) {
  const model = body.model ?? ctx.model
  if (typeof model !== 'string') return
  const match = /^(.*?)(:(?:none|minimal|low|medium|high|xhigh|max))?(\[1m\])?$/.exec(model)
  const target = ctx.options?.routes?.[match[1]]
  if (target) return { ...body, model: target + (match[2] ?? '') + (match[3] ?? '') }
}
