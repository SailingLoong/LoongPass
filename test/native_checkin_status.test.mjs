import { expect, test } from 'bun:test'
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// Run against the pinned package, or a private replay of the source patch.
const runtime = process.env.LOONGPASS_CHECKIN_RUNTIME || fileURLToPath(new URL('../runtime', import.meta.url))

async function native(provider, answer, { claim = false, failure = false, expectedScope } = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'loongpass-status-plugin-'))
  try {
    await mkdir(join(directory, 'home'))
    const runner = join(directory, 'fixture.mjs')
    await writeFile(runner, `
      import { pathToFileURL } from 'node:url';
      const input = ${JSON.stringify({ provider, answer, claim, failure, expectedScope })};
      const calls = [];
      const endpoints = {
        workbuddy: ['/v2/billing/meter/checkin-activity-status', '/v2/billing/meter/daily-checkin'],
        minimax: ['/minimax-cloud/api/v1/signin/status', '/minimax-cloud/api/v1/signin/claim'],
        qoder: ['/sash/api/v1/me/campaigns', '/sash/api/v1/me/campaigns/campaign-a/claim'],
        trae: ['/trae/api/v2/ug/checkin_credits/status', '/trae/api/v2/ug/checkin_credits/claim'],
      };
      globalThis.fetch = async (inputURL, init = {}) => {
        const u = new URL(String(inputURL));
        const index = endpoints[input.provider].indexOf(u.pathname);
        if (index < 0) throw Error('Unexpected fixture request: ' + u.pathname);
        calls.push({path: u.pathname, method: init.method || 'GET'});
        if (input.failure) throw Error('synthetic read failed');
        const answer = index === 0 ? (input.provider === 'trae' && calls.some(c => c.path.endsWith('/claim'))
          ? {checked_in: true, enable: true, credits: 12.5} : input.answer) : ({
          workbuddy: {code: 0, data: {credit: 12.5, streak_days: 3}},
          minimax: {data: {claim_result: 1, points: 12.5}},
          qoder: {status: 'CLAIMED', benefit: {amount: 12.5}},
          trae: {credits: 12.5},
        })[input.provider];
        return Response.json(answer);
      };
      const names = {workbuddy: 'WorkBuddyAuthPlugin', minimax: 'MiniMaxCodeAuthPlugin', qoder: 'QoderCNAuthPlugin', trae: 'TraeCNAuthPlugin'};
      const module = await import(pathToFileURL(process.argv[2]).href);
      const hooks = await module[names[input.provider]]({client: {auth: {set: async () => {}}}});
      const auth = {type: 'oauth', uid: 'synthetic-account', realUserID: 'synthetic-account', accountId: 'synthetic-account', access: 'fake', refresh: '', expires: 4102444800000, patAuth: true};
      let result, error;
      try { result = await hooks.auth[input.claim ? 'checkin' : 'checkinStatus'](async () => auth, {id: hooks.auth.provider}, {expectedScope: input.expectedScope}); }
      catch (e) { error = e.message; }
      process.stdout.write(JSON.stringify({result, error, calls}));
    `)
    // Qoder CN explicitly tolerates an unavailable identity helper. A private
    // missing override prevents even searching the user's installed client.
    const child = Bun.spawn([process.execPath, runner, join(runtime, 'vendor/plugins', provider, 'index.mjs')], {
      cwd: directory, env: { ...process.env, HOME: join(directory, 'home'), QODERCN_RUNTIME_INFO: join(directory, 'missing-runtime') },
      stdout: 'pipe', stderr: 'pipe',
    })
    const [output, error, exit] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited])
    expect(exit, error).toBe(0)
    return JSON.parse(output)
  } finally { await rm(directory, { recursive: true, force: true }) }
}

const days = status => Array.from({ length: 7 }, (_, i) => ({ day_no: i + 1, is_today: i === 2, status: i === 2 ? status : 1, points: 12.5 }))
const campaign = (claimStatus = 'CLAIMABLE', more = {}) => ({
  campaigns: [{ actionType: 'CLAIM_BENEFIT', campaignId: 'campaign-a', claimStatus,
    startAt: Math.floor(Date.now() / 1000) - 3600, endAt: Math.floor(Date.now() / 1000) + 3600, benefit: { amount: 12.5 }, ...more }],
})
const eligible = {
  workbuddy: { code: 0, data: { active: true, today_checked_in: false } },
  minimax: { data: { days: days(2) } },
  qoder: campaign(),
  trae: { checked_in: false, enable: true },
}

for (const provider of Object.keys(eligible)) {
  test(`${provider}: public readonly hook stops before its existing claim request`, async () => {
    const read = await native(provider, eligible[provider])
    expect(read.error).toBeUndefined()
    expect(read.result.outcome).toBe('claimable')
    expect(read.calls).toHaveLength(1)
    // The native status transport includes POST on WB/TRAE; HTTP verbs cannot
    // identify reward mutations. The owner declares the read boundary.
    expect(read.calls[0].method).toBe(['workbuddy', 'trae'].includes(provider) ? 'POST' : 'GET')
    if (provider !== 'qoder') expect(read.result.scope).toBeUndefined()
  })
  test(`${provider}: normal public checkin still follows the same read with a claim`, async () => {
    const read = await native(provider, eligible[provider], { claim: true })
    expect(read.error).toBeUndefined()
    expect(read.calls.filter(c => /claim$|daily-checkin$/.test(c.path))).toHaveLength(1)
    expect(read.result.outcome).toBe('claimed')
    expect(read.result.credit).toBe(12.5)
  })
  test(`${provider}: missing status fields cannot claim or become a definitive negative`, async () => {
    const read = await native(provider, provider === 'minimax' ? { data: { days: days(undefined) } } : {})
    expect(read.result?.outcome ?? 'unknown').toBe('unknown')
    expect(read.calls).toHaveLength(1)
  })
  test(`${provider}: failed status read never submits a reward mutation`, async () => {
    const read = await native(provider, {}, { failure: true })
    expect(read.calls.length).toBeGreaterThan(0)
    expect(read.calls.every(c => /status$|campaigns$/.test(c.path))).toBe(true)
    expect(['failed', 'unknown', undefined]).toContain(read.result?.outcome)
  })
}

for (const [provider, answer, outcome] of [
  ['workbuddy', {code: 0, data: {active: true, today_checked_in: true, today_credit: 12.5}}, 'done'],
  ['workbuddy', {code: 0, data: {active: false}}, 'inactive'],
  ['minimax', {data: {days: days(3)}}, 'done'],
  ['minimax', {data: {days: days(4)}}, 'ineligible'],
  ['minimax', {data: {days: days(1)}}, 'inactive'],
  ['trae', {checked_in: true, credits: 12.5}, 'done'],
  ['trae', {checked_in: false, enable: false}, 'inactive'],
]) {
  test(`${provider}: readonly native ${outcome} evidence remains definitive without a claim`, async () => {
    const read = await native(provider, answer)
    expect(read.error).toBeUndefined()
    expect(read.result.outcome).toBe(outcome)
    expect(read.calls).toHaveLength(1)
    if (outcome === 'done') expect(read.result.credit).toBe(12.5)
    expect(read.result.scope).toBeUndefined()
  })
}

test('Qoder status retains official campaign identity/boundaries and exact credits across claimable/done', async () => {
  const offered = campaign()
  const read = await native('qoder', offered)
  offered.campaigns[0].claimStatus = 'CLAIMED'
  const done = await native('qoder', offered)
  expect(read.result.scope).toBeTruthy()
  expect(done.result.scope).toBe(read.result.scope)
  expect(done.result.outcome).toBe('done')
  expect(done.result.credit).toBe(12.5)
  expect(done.result.until).toBe(read.result.until)
  expect((await native('qoder', campaign('CLAIMABLE', { endAt: undefined }))).result.scope).toBeUndefined()
})

test('Qoder binds the actual claim to the observed cycle and refuses a cycle turn without POST', async () => {
  const offered = campaign()
  const status = await native('qoder', offered)
  const same = await native('qoder', offered, { claim: true, expectedScope: status.result.scope })
  expect(same.result.outcome).toBe('claimed')
  expect(same.result.scope).toBe(status.result.scope)
  const next = structuredClone(offered)
  next.campaigns[0].startAt += 86400
  next.campaigns[0].endAt += 86400
  const changed = await native('qoder', next, { claim: true, expectedScope: status.result.scope })
  expect(changed.result.outcome).toBe('failed')
  expect(changed.result.message).toContain('scope changed')
  expect(changed.calls.map(c => c.method)).toEqual(['GET'])
})

test('native host advertises only declared status hooks, isolates accounts and sanitizes failures', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'loongpass-status-host-'))
  let child, pump
  const pending = new Map()
  try {
    const plugin = join(directory, 'plugin.mjs'), preload = join(directory, 'preload.mjs')
    await writeFile(preload, `globalThis.fetch = async () => { throw Error('No network in status host test'); };`)
    await writeFile(plugin, `
      import {appendFileSync} from 'node:fs';
      export const Fixture = async (_, options) => ({
        config: async c => { c.provider ??= {}; c.provider[options.id] = {name: options.id, models: {one: {name: 'One'}}}; },
        auth: {provider: options.id, methods: [],
          checkin: async (getAuth, _provider, context) => {
            appendFileSync('claims', JSON.stringify(context));
            const a = await getAuth();
            return a.claim ?? {outcome: 'claimed', scope: context?.expectedScope};
          },
          ...(options.supported ? {checkinStatus: async getAuth => {
            const a = await getAuth();
            await Bun.sleep(a.uid === 'slow' ? 15 : 0);
            if (a.uid === 'throws') throw Error('private-secret-not-a-message');
            return a.result ?? {outcome: 'claimable', scope: a.uid, until: 1794153600000};
          }} : {}),
        },
      });
    `)
    child = Bun.spawn([process.execPath, '--preload', preload, resolve(runtime, 'vendor/magpie/host.js')],
      { cwd: directory, env: { ...process.env, HOME: directory }, stdin: 'pipe', stdout: 'pipe', stderr: 'pipe' })
    const errors = new Response(child.stderr).text()
    pump = (async () => {
      let buffer = ''
      for await (const part of child.stdout) {
        buffer += new TextDecoder().decode(part)
        let index
        while ((index = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, index); buffer = buffer.slice(index + 1)
          if (!line) continue
          const reply = JSON.parse(line), waiting = pending.get(reply.id)
          if (!waiting || reply.event) continue
          pending.delete(reply.id); clearTimeout(waiting.timer)
          reply.error ? waiting.reject(Error(reply.error.message)) : waiting.resolve(reply.result)
        }
      }
    })()
    let next = 0
    const rpc = (method, params) => new Promise((resolve, reject) => {
      const id = ++next, timer = setTimeout(() => reject(Error(`${method} timeout`)), 5000)
      pending.set(id, { resolve, reject, timer })
      child.stdin.write(JSON.stringify({ id, method, params }) + '\n'); child.stdin.flush()
    })
    const initialized = await rpc('init', { directory, authPath: join(directory, 'auth.json'), plugins: [
      { spec: 'fixture', target: plugin, options: { id: 'fixture', supported: true } },
      { spec: 'no-status', target: plugin, options: { id: 'no-status', supported: false } },
    ] })
    expect(initialized.plugins.every(p => !p.error)).toBe(true)
    const fixtures = [{ uid: 'slow' }, { uid: 'fast' }, { uid: 'throws' },
      { uid: 'missing', result: {} }, { uid: 'failed', result: { outcome: 'failed', message: 'private-secret-not-a-message' } },
      { uid: 'done', result: { outcome: 'done', credit: 12.5, scope: 'official-cycle', until: '2026-11-09T00:00:00Z' } },
      { uid: 'zero', claim: { outcome: 'claimed', credit: 0 } },
      { uid: 'decimal', claim: { outcome: 'claimed', credit: 12.5 } },
      { uid: 'negative', claim: { outcome: 'claimed', credit: -1 } },
      { uid: 'text-credit', claim: { outcome: 'claimed', credit: '12.5' } },
      { uid: 'missing-failed', claim: { outcome: 'failed' } },
      { uid: 'invalid-outcome', claim: { outcome: 'unexpected' } },
    ]
    for (const a of fixtures) await rpc('import', { provider: 'fixture', key: `fixture#${a.uid}`, auth: { type: 'oauth', access: 'fake', refresh: '', expires: 0, ...a } })
    await rpc('import', { provider: 'no-status', key: 'no-status#a', auth: { type: 'oauth', uid: 'a', access: 'fake', refresh: '', expires: 0 } })
    const providers = await rpc('providers', {})
    expect(providers.find(p => p.id === 'fixture').checkinStatus).toBe(true)
    expect(providers.find(p => p.id === 'no-status').checkinStatus).toBe(false)
    const results = await Promise.all(fixtures.map(a => rpc('checkinStatus', { provider: 'fixture', account: `fixture#${a.uid}` })))
    expect(results[0].scope).toBe('slow')
    expect(results[1].scope).toBe('fast')
    for (const result of results.slice(2, 5)) {
      expect(result.outcome).toBe('unknown')
      expect(JSON.stringify(result)).not.toContain('private-secret')
      expect(result.credit).toBeUndefined()
    }
    expect(results[5]).toMatchObject({ outcome: 'done', credit: 12.5, scope: 'official-cycle', until: '2026-11-09T00:00:00.000Z' })
    expect(await rpc('checkinStatus', { provider: 'no-status', account: 'no-status#a' })).toMatchObject({ outcome: 'unknown' })
    expect(await readFile(join(directory, 'claims'), 'utf8').catch(() => '')).toBe('')
    const claimed = await rpc('checkin', {provider: 'fixture', account: 'fixture#slow', expectedScope: 'official-bound-cycle'})
    expect(claimed).toMatchObject({outcome: 'claimed', scope: 'official-bound-cycle'})
    expect(claimed.credit).toBeUndefined()
    expect(JSON.parse(await readFile(join(directory, 'claims'), 'utf8'))).toEqual({expectedScope: 'official-bound-cycle'})
    for (const uid of ['zero', 'decimal', 'negative', 'text-credit', 'missing-failed', 'invalid-outcome']) {
      const receipt = await rpc('checkin', {provider: 'fixture', account: `fixture#${uid}`})
      expect(receipt.credit).toBe(uid === 'zero' ? 0 : uid === 'decimal' ? 12.5 : undefined)
    }
    child.kill(); await child.exited; await errors
  } finally {
    child?.kill(); if (child) await child.exited
    await pump
    for (const waiting of pending.values()) clearTimeout(waiting.timer)
    await rm(directory, { recursive: true, force: true })
  }
})
