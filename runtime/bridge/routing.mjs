// Runs inside Magpie's native gateway, before its protocol conversion. Quota
// facts are a one-way snapshot from LoongPass, never refreshed on this path.
export function onRequest(body, ctx) {
  const model = body.model ?? ctx.model
  if (typeof model !== 'string') return
  const match = /^(.*?)(:(?:none|minimal|low|medium|high|xhigh|max))?(\[1m\])?$/.exec(model)
  const target = ctx.options?.routes?.[match[1]]
  if (target) return { ...body, model: target + (match[2] ?? '') + (match[3] ?? '') }
}

export const strategies = {
  quota(pool, seats, options) {
    const accounts = options?.pools?.[pool]
    if (!accounts) return seats.map((_, index) => index)
    const now = Date.now()
    const ranked = seats.map((seat, index) => {
      const account = seat.key === 'loongpass' ? options.defaultAccount : seat.key.replace(/^loongpass@/, '')
      const quota = accounts[account]
      // The pinned native router counts a non-ordered provider at 98% as
      // spent. Native session affinity runs after this strategy and retains
      // the previously successful account while the gateway considers it ready.
      const unavailable = quota?.available === false || (seat.known && seat.used >= 98)
      const expires = (quota?.expires ?? []).filter(at => Number.isFinite(at) && at > now)
      return { index, tier: seat.resting ? 2 : unavailable ? 1 : 0,
        at: expires.length ? Math.min(...expires) : Infinity, account: account ?? seat.key }
    })
    ranked.sort((a, b) => a.tier - b.tier || a.at - b.at || a.account.localeCompare(b.account) || a.index - b.index)
    return ranked.map(row => row.index)
  },
}
