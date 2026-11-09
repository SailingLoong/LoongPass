import { expect, test } from 'bun:test'
import { mkdtemp, mkdir, writeFile, utimes, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { QoderAuthPlugin, _internal } from '../runtime/vendor/plugins/qoder/index.mjs'

const trial = used => ({ displayMode: 'qoder', qoderUsage: {
  userType: 'personal_professional_trial',
  userQuota: { total: 800, used, remaining: 800 - used, unit: 'credits' },
} })

async function account(state, run) {
  const original = globalThis.fetch
  const calls = { usage: 0, refresh: 0, chats: 0 }
  let auth = {
    type: 'oauth', uid: 'synthetic-quota-account', accountId: 'fixture@example.test',
    access: 'jt-fixture', refresh: 'jrt-fixture', expires: Date.now() + 86400000,
    deviceToken: 'dt-fixture', deviceRefresh: 'drt-fixture', machineId: 'synthetic-machine',
  }
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(String(input))
    if (url.pathname.endsWith('/model/list')) {
      return Response.json({ app: [
        { key: 'dfmodel', display_name: 'Fixture model', enable: !state.off },
        { key: 'qfmodel', display_name: 'Enabled fixture', enable: true },
      ], byok_teams: [], byok_enterprise: [] })
    }
    if (url.pathname === '/sash/api/v2/me/usage') {
      calls.usage++
      expect(new Headers(init.headers).get('authorization')).toBe('Bearer dt-fixture')
      return Response.json(state.usage, { status: state.usageStatus ?? 200 })
    }
    if (url.pathname === '/api/v1/jobToken/refresh') {
      calls.refresh++
      return Response.json({ token: 'jt-renewed', refresh_token: 'jrt-renewed', expires_in: 86400000 })
    }
    if (url.pathname.endsWith('/sse/agent_chat_generation')) {
      calls.chats++
      const frame = body => `data:${JSON.stringify({ headers: {}, body: typeof body === 'string' ? body : JSON.stringify(body), statusCodeValue: 200 })}\n\n`
      return new Response(frame({ choices: [{ index: 0, delta: { content: 'ok' } }] })
        + frame({ choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] }) + frame('[DONE]'),
      { headers: { 'content-type': 'text/event-stream' } })
    }
    throw new Error(`Unexpected synthetic Qoder request ${url.pathname}`)
  }
  try {
    const hooks = await QoderAuthPlugin({ client: { auth: { set: async ({ body }) => { auth = body } } } })
    const loader = await hooks.auth.loader(async () => auth)
    const ask = model => loader.fetch('https://api3.qoder.sh/v1/chat/completions', {
      method: 'POST', body: JSON.stringify({ model, messages: [{ role: 'user', content: 'synthetic quota check' }] }),
    })
    await run(ask, calls)
  } finally {
    globalThis.fetch = original
  }
}

test('disabled model with 800 of 800 credits used returns quota 429 before renewal', async () => {
  await account({ off: true, usage: trial(800) }, async (ask, calls) => {
    const reply = await ask('dfmodel')
    expect(reply.status).toBe(429)
    expect((await reply.json()).error.message).toContain('800 / 800 credits')
    expect(reply.headers.get('x-magpie-sign-in')).toBeNull()
    expect(calls).toEqual({ usage: 1, refresh: 0, chats: 0 })
    expect((await ask('qfmodel')).status).toBe(200)
  })
})

for (const scenario of [
  { name: 'remaining credits', used: 200, model: 'dfmodel', usageStatus: 200, reads: 1 },
  { name: 'unavailable usage', used: 800, model: 'dfmodel', usageStatus: 500, reads: 1 },
  { name: 'unknown model', used: 800, model: 'nonexistent-model', usageStatus: 200, reads: 0 },
]) {
  test(`${scenario.name} retains request 400 without claiming exhausted quota`, async () => {
    await account({ off: true, usage: trial(scenario.used), usageStatus: scenario.usageStatus }, async (ask, calls) => {
      const reply = await ask(scenario.model)
      expect(reply.status).toBe(400)
      expect((await reply.json()).error.message).toContain('unknown or disabled model')
      expect(calls.usage).toBe(scenario.reads)
      expect(calls.chats).toBe(0)
    })
  })
}

test('a restored listing serves the model after credits return', async () => {
  const state = { off: true, usage: trial(800) }
  await account(state, async ask => {
    expect((await ask('dfmodel')).status).toBe(429)
    state.off = false
    state.usage = trial(0)
    expect((await ask('dfmodel')).status).toBe(200)
  })
})

test('a present add-on pool with incomplete data prevents an exhausted-account response', async () => {
  for (const addOnQuota of [
    { remaining: 60, unit: 'credits' },
    { total: null, used: null, remaining: null },
    { total: -1, used: 0 },
    { total: 100 },
    'unavailable',
  ]) {
    const usage = trial(800)
    usage.qoderUsage.addOnQuota = addOnQuota
    expect(_internal.spentOf(usage)).toBe('')
    await account({ off: true, usage }, async (ask, calls) => {
      const reply = await ask('dfmodel')
      expect(reply.status).toBe(400)
      expect((await reply.json()).error.message).toContain('unknown or disabled model')
      expect(calls).toEqual({ usage: 1, refresh: 1, chats: 0 })
    })
  }
})

test('spent pools require exact totals and preserve available add-on credits', () => {
  expect(_internal.spentOf(trial(800))).toBe('800 / 800 credits')
  expect(_internal.spentOf(trial(799))).toBe('')
  expect(_internal.spentOf({ displayMode: 'qoder', qoderUsage: {
    userQuota: { total: 300, used: 300 }, addOnQuota: { total: 100, used: 40 },
  } })).toBe('')
  expect(_internal.spentOf({ displayMode: 'qoder', qoderUsage: {
    userQuota: { total: 300, used: 300 }, add_on_quota: { total: 100, remaining: 0 },
  } })).toBe('400 / 400 credits')
  expect(_internal.spentOf({ displayMode: 'qoder', qoderUsage: { userQuota: { total: 800 } } })).toBe('')
  expect(_internal.spentOf({ displayMode: 'qoder', qoderUsage: {
    userQuota: { total: 800, used: 800 }, addOnQuota: null,
  } })).toBe('800 / 800 credits')
})

for (const arch of ['x64', 'arm64']) {
  test(`Windows ${arch} CLI helper selection handles new files and legacy folders`, async () => {
    const home = await mkdtemp(join(tmpdir(), 'loongpass-qoder-helper-'))
    try {
      const cache = join(home, '.qoder', '.bin')
      await mkdir(cache, { recursive: true })
      const old = join(cache, `umid-win32-${arch}-old`, 'runtime-info.exe')
      await mkdir(join(cache, `umid-win32-${arch}-old`))
      await writeFile(old, 'synthetic helper, never executed')
      await utimes(old, new Date(1000), new Date(1000))
      const current = join(cache, `runtime-info-win32-${arch}-new.exe`)
      await writeFile(current, 'synthetic helper, never executed')
      await utimes(current, new Date(2000), new Date(2000))
      for (const name of [`runtime-info-win32-${arch}-writing.exe.tmp`, `runtime-info-win32-${arch === 'x64' ? 'arm64' : 'x64'}-other.exe`, 'sgsdk.dll']) {
        const path = join(cache, name)
        await writeFile(path, 'ignored synthetic file')
        await utimes(path, new Date(3000), new Date(3000))
      }
      const options = { home, platform: 'win32', arch, env: { LOCALAPPDATA: join(home, 'Local'), ProgramFiles: join(home, 'Programs') } }
      expect(await _internal.campaignRuntime(options)).toBe(current)
      await utimes(old, new Date(4000), new Date(4000))
      expect(await _internal.campaignRuntime(options)).toBe(old)
    } finally {
      await rm(home, { recursive: true, force: true })
    }
  })
}
