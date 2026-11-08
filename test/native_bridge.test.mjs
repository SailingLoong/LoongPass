import { expect, test } from 'bun:test'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import LoongPassPlugin, { LoongPassPlugin as namedPlugin } from '../runtime/bridge/index.mjs'

const endpoint = 'http://127.0.0.1:3426'
const grant = (key = 'synthetic-grant-a', extra = {}) => ({ type: 'api', key, metadata: { endpoint, email: 'opaque/account-a', ...extra } })
const anthropic = {
  id: 'claude-native', name: 'Native Claude', apiId: 'claude-api', npm: '@ai-sdk/anthropic', url: 'https://native.invalid/anthropic',
  context: 200000, input: 180000, output: 8192, reasoning: true, image: true, imageSaid: true,
  inputs: ['text', 'image', 'pdf'], inputsSaid: true, outputs: ['text'], outputsSaid: true,
  cost: { input: 3, output: 15, cache: { read: 0.3, write: 3.75 } }, variants: ['low', 'high'],
  free: false, rate: 0.8, rateWas: 1.6, temperature: false, released: '2026-10-01',
  fast: true, serviceTiers: ['priority', 'ultrafast'], decides: false, searches: true,
}
const chat = {
  id: 'chat/native', name: 'Native Chat', apiId: 'chat-api', npm: '@ai-sdk/openai-compatible', url: 'https://native.invalid/v1',
  context: 65536, input: 60000, output: 4096, reasoning: false, image: false, imageSaid: false,
  inputs: ['text'], inputsSaid: false, outputs: ['text'], outputsSaid: true,
  cost: { input: 0, output: 0, cache: { read: 0, write: 0 } }, variants: [], free: true, rate: 1, rateWas: 0,
  released: '', fast: false, serviceTiers: [], decides: true, searches: false,
}
const snapshot = (provider = 'workbuddy', models = [anthropic, chat]) => ({
  account: { id: 'native-account-a', provider, label: 'Account A' }, models,
  usage: { user: 'Account A', windows: [{ name: 'Credits', amount: 25, limit: 100, unit: 'credits', used: 25 }] },
  maxConcurrency: 2, maxAccounts: 1,
})

async function withFetch(fake, run) {
  const original = globalThis.fetch
  globalThis.fetch = fake
  try { return await run() } finally { globalThis.fetch = original }
}

test('public factory declares one API account method and leaves protocol and scheduler ownership native', async () => {
  expect(namedPlugin).toBe(LoongPassPlugin)
  const hooks = await LoongPassPlugin({})
  const config = { provider: { other: { name: 'Other' }, loongpass: { options: { user: true } } } }
  await hooks.config(config)
  expect(config.provider.loongpass).toEqual({ name: 'LoongPass', options: { user: true } })
  expect(config.provider.other).toEqual({ name: 'Other' })
  expect(hooks.auth.provider).toBe('loongpass')
  expect(hooks.provider.id).toBe('loongpass')
  expect(hooks.auth.methods).toHaveLength(1)
  const method = hooks.auth.methods[0]
  expect(method.type).toBe('api')
  expect(method.authorize).toBeUndefined()
  expect(method.prompts.map(p => p.key)).toEqual(['endpoint', 'email'])
  expect(method.prompts[0].placeholder).toBe(endpoint)
  expect(method.prompts[0].validate('')).toBeUndefined()
  expect(method.prompts[1].validate('opaque/not-an-email')).toBeUndefined()
  expect(method.prompts[1].validate(' ')).toBeDefined()
  expect(hooks.auth.checkin).toBeUndefined()
  expect(hooks.auth.maxConcurrency).toBeUndefined()
  expect(hooks.auth.maxAccounts).toBeUndefined()
  const loader = await hooks.auth.loader(async () => grant())
  expect(loader.apiKey).toBe('loongpass')
  expect(loader.baseURL).toBeUndefined()
})

test('catalogue preserves mixed native protocol, capability, cost and routing metadata per account', async () => {
  const hooks = await LoongPassPlugin({})
  const ctl = new AbortController()
  await withFetch(async (url, init) => {
    expect(String(url)).toBe(`${endpoint}/plugin/catalog`)
    expect(init.method).toBe('GET')
    expect(init.redirect).toBe('error')
    expect(init.signal).toBe(ctl.signal)
    expect(new Headers(init.headers).get('authorization')).toBe('Bearer synthetic-grant-a')
    return Response.json(snapshot())
  }, async () => {
    const models = await hooks.provider.models({ models: {} }, { auth: grant(), signal: ctl.signal })
    expect(Object.keys(models)).toEqual(['workbuddy/claude-native', 'workbuddy/chat/native'])
    const a = models['workbuddy/claude-native'], b = models['workbuddy/chat/native']
    expect(a.api).toEqual({ id: 'claude-api', npm: '@ai-sdk/anthropic', url: 'https://native.invalid/anthropic' })
    expect(b.api).toEqual({ id: 'chat-api', npm: '@ai-sdk/openai-compatible', url: 'https://native.invalid/v1' })
    expect(a.limit).toEqual({ context: 200000, input: 180000, output: 8192 })
    expect(a.capabilities.input).toEqual({ text: true, image: true, audio: false, video: false, pdf: true })
    expect(a.capabilities.output).toEqual({ text: true, image: false, audio: false, video: false, pdf: false })
    expect(b.capabilities.input).toEqual({ text: true })
    expect(a.capabilities.reasoning).toBe(true)
    expect(a.cost).toEqual({ input: 3, output: 15, cache: { read: 0.3, write: 3.75 } })
    expect(b.cost).toEqual({ input: 0, output: 0, cache: { read: 0, write: 0 } })
    expect(a.variants).toEqual({ low: {}, high: {} })
    expect(a.rate).toBe(0.8)
    expect(a.rateWas).toBe(1.6)
    expect(a.free).toBe(false)
    expect(b.free).toBe(true)
    expect(a.temperature).toBe(false)
    expect(b.temperature).toBeUndefined()
    expect(a.release_date).toBe('2026-10-01')
    expect(a.fast).toBe(true)
    expect(a.serviceTiers).toEqual(['priority', 'ultrafast'])
    expect(a.searches).toBe(true)
    expect(b.decides).toBe(true)
    expect(hooks.auth.maxConcurrency).toBeUndefined()
    expect(hooks.auth.maxAccounts).toBeUndefined()
  })
})

test('declared input kinds do not turn unspecified image capability into an explicit refusal', async () => {
  const hooks = await LoongPassPlugin({})
  await withFetch(async () => Response.json(snapshot('qoder-cn', [{ ...chat, inputs: ['text', 'audio'], inputsSaid: true }])), async () => {
    const models = await hooks.provider.models({}, { auth: grant() })
    expect(models['qoder-cn/chat/native'].capabilities.input.image).toBeUndefined()
    expect(models['qoder-cn/chat/native'].capabilities.input.audio).toBe(true)
  })
})

for (const bad of ['https://127.0.0.1:3426', 'http://localhost:3426', 'http://127.1:3426', 'http://2130706433:3426',
  'http://0x7f000001:3426', 'http://127.0.0.1.example:3426', 'http://example.invalid', 'http://user:pass@127.0.0.1:3426',
  `${endpoint}/path`, `${endpoint}?key=value`, `${endpoint}#fragment`, 'http://[::ffff:127.0.0.1]:3426', 'http://127.0.0.1:99999']) {
  test(`rejects noncanonical loopback origin without sending a grant: ${bad}`, async () => {
    const hooks = await LoongPassPlugin({})
    await withFetch(() => { throw new Error('must not fetch an invalid endpoint') }, async () => {
      expect(hooks.auth.methods[0].prompts[0].validate(bad)).toBeDefined()
      await expect(hooks.provider.models({}, { auth: grant('synthetic', { endpoint: bad }) })).rejects.toThrow('loopback')
    })
  })
}

test('empty endpoint uses the default and IPv6 loopback stays local', async () => {
  const hooks = await LoongPassPlugin({})
  const urls = []
  await withFetch(async url => { urls.push(String(url)); return Response.json(snapshot()) }, async () => {
    await hooks.provider.models({}, { auth: grant('a', { endpoint: '' }) })
    await hooks.provider.models({}, { auth: grant('b', { endpoint: 'http://[::1]:3427/' }) })
  })
  expect(urls).toEqual([`${endpoint}/plugin/catalog`, 'http://[::1]:3427/plugin/catalog'])
})

test('snapshot failure and missing native protocol data are errors instead of invented models', async () => {
  const hooks = await LoongPassPlugin({})
  await withFetch(async () => new Response('private detail', { status: 503 }), async () => {
    await expect(hooks.provider.models({}, { auth: grant() })).rejects.toThrow('503')
  })
  await withFetch(async () => Response.json(snapshot('qoder-cn', [{ id: 'missing-protocol' }])), async () => {
    await expect(hooks.provider.models({}, { auth: grant() })).rejects.toThrow('native model')
  })
})

test('usage reads only its account snapshot and propagates cancellation', async () => {
  const hooks = await LoongPassPlugin({})
  const ctl = new AbortController()
  await withFetch(async (url, init) => {
    expect(String(url)).toBe(`${endpoint}/plugin/catalog`)
    expect(init.signal).toBe(ctl.signal)
    return Response.json(snapshot())
  }, async () => {
    expect(await hooks.auth.usage(async () => grant(), {}, { signal: ctl.signal })).toEqual(snapshot().usage)
  })
})

test('chat header hook marks only LoongPass requests with native model id and session', async () => {
  const hooks = await LoongPassPlugin({})
  const output = { headers: { existing: 'kept' } }
  await hooks['chat.headers']({ model: { id: 'workbuddy/claude-native', providerID: 'loongpass' }, sessionID: 'session-1' }, output)
  expect(output.headers).toEqual({ existing: 'kept', 'x-loongpass-model': 'workbuddy/claude-native', 'x-loongpass-session': 'session-1' })
  const other = { headers: {} }
  await hooks['chat.headers']({ model: { id: 'other', providerID: 'other' }, sessionID: 'wrong' }, other)
  expect(other.headers).toEqual({})
})

test('fetch envelopes exact request bytes and all native context before host header stripping', async () => {
  const hooks = await LoongPassPlugin({})
  let auth = grant()
  const loader = await hooks.auth.loader(async () => auth)
  auth = grant('rotated-local-grant')
  const bytes = new Uint8Array([0, 255, 239, 187, 191, 128, 10])
  const request = new Request('https://native.invalid/anthropic/messages?beta=true', {
    method: 'POST', body: bytes, headers: {
      'x-loongpass-model': 'workbuddy/claude-native', 'x-loongpass-session': 'session-native',
      'x-magpie-work-dir': '/synthetic/project', 'x-magpie-work-git': 'branch',
      'x-magpie-fallback': '1', 'x-magpie-session': 'native-session', 'x-magpie-subagent': 'worker',
      'x-magpie-new-context': 'kept', 'x-api-key': 'loongpass', 'x-goog-api-key': 'loongpass', authorization: 'Bearer loongpass',
      'content-type': 'application/octet-stream', 'anthropic-version': '2023-06-01', 'x-override': 'old',
    },
  })
  const reply = new Response('vendor detail', { status: 429, headers: { 'retry-after': '7', 'x-magpie-sign-in': 'kept' } })
  await withFetch(async (url, init) => {
    expect(String(url)).toBe(`${endpoint}/plugin/fetch`)
    expect(init.method).toBe('POST')
    expect(init.redirect).toBe('error')
    expect(Object.fromEntries(new Headers(init.headers))).toEqual({ authorization: 'Bearer rotated-local-grant', 'content-type': 'application/json' })
    const body = JSON.parse(init.body)
    expect(body).toEqual({ model: 'workbuddy/claude-native', url: request.url, method: 'POST', session: 'session-native', body: 'AP/vu7+ACg==', headers: {
      'x-magpie-work-dir': '/synthetic/project', 'x-magpie-work-git': 'branch', 'x-magpie-fallback': '1',
      'x-magpie-session': 'native-session', 'x-magpie-subagent': 'worker', 'x-magpie-new-context': 'kept',
      'content-type': 'application/octet-stream', 'anthropic-version': '2023-06-01', 'x-override': 'new',
    } })
    return reply
  }, async () => {
    const result = await loader.fetch(request, { headers: { 'x-override': 'new' } })
    expect(result).toBe(reply)
    expect(result.status).toBe(429)
    expect(result.headers.get('retry-after')).toBe('7')
    expect(await result.text()).toBe('vendor detail')
  })
})

test('fetch requires the model marker and valid local credentials before dispatch', async () => {
  const hooks = await LoongPassPlugin({})
  const loader = await hooks.auth.loader(async () => grant())
  await withFetch(() => { throw new Error('must not dispatch') }, async () => {
    await expect(loader.fetch('https://native.invalid/v1', { method: 'POST', body: '{}' })).rejects.toThrow('model')
    await expect(hooks.auth.loader(async () => ({ type: 'api', key: '' }))).rejects.toThrow('grant')
  })
})

test('abort during body capture cancels the source and never sends a local request', async () => {
  const hooks = await LoongPassPlugin({})
  const loader = await hooks.auth.loader(async () => grant())
  const ctl = new AbortController()
  let cancelled = false
  const request = new Request('https://native.invalid/v1', { method: 'POST', signal: ctl.signal,
    headers: { 'x-loongpass-model': 'qoder-cn/chat' }, body: new ReadableStream({ cancel() { cancelled = true } }),
  })
  await withFetch(() => { throw new Error('must not dispatch cancelled body') }, async () => {
    const waiting = loader.fetch(request)
    queueMicrotask(() => ctl.abort(new Error('cancelled-body')))
    await expect(waiting).rejects.toThrow('cancelled-body')
    expect(cancelled).toBe(true)
  })
})

test('response streams without waiting for completion and abort reaches the local transport', async () => {
  const hooks = await LoongPassPlugin({})
  const loader = await hooks.auth.loader(async () => grant())
  const ctl = new AbortController()
  await withFetch(async (_, init) => new Response(new ReadableStream({ start(controller) {
    controller.enqueue(new TextEncoder().encode('data: first\n\n'))
    init.signal.addEventListener('abort', () => controller.error(init.signal.reason), { once: true })
  } }), { headers: { 'content-type': 'text/event-stream' } }), async () => {
    const response = await loader.fetch('https://native.invalid/v1/chat/completions', { method: 'POST', signal: ctl.signal,
      headers: { 'x-loongpass-model': 'qoder-cn/chat' }, body: '{"stream":true}',
    })
    const reader = response.body.getReader()
    expect(new TextDecoder().decode((await reader.read()).value)).toBe('data: first\n\n')
    const failed = reader.read()
    ctl.abort(new Error('cancelled-stream'))
    await expect(failed).rejects.toThrow('cancelled-stream')
  })
})

test('upstream stream failure is preserved without replay or a fabricated successful ending', async () => {
  const hooks = await LoongPassPlugin({})
  const loader = await hooks.auth.loader(async () => grant())
  let sends = 0
  await withFetch(async () => {
    sends++
    return new Response(new ReadableStream({ start(c) { c.error(new Error('broken-native-stream')) } }), { status: 200 })
  }, async () => {
    const response = await loader.fetch('https://native.invalid/messages', { method: 'POST', headers: { 'x-loongpass-model': 'workbuddy/claude-native' }, body: '{}' })
    await expect(response.text()).rejects.toThrow('broken-native-stream')
    expect(sends).toBe(1)
  })
})

test('pinned native host loads the package, deduplicates grant identities and round-trips native model DTOs', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'loongpass-bridge-test-'))
  let child
  const pending = new Map()
  let pump, stderr
  try {
    const preload = join(directory, 'fetch-fixture.mjs')
    await writeFile(preload, `const catalog = ${JSON.stringify(snapshot())};\nglobalThis.fetch = async (input, init = {}) => {
      const url = String(input), headers = new Headers(init.headers);
      if (url === '${endpoint}/plugin/catalog') return Response.json(headers.get('authorization') === 'Bearer synthetic-second'
        ? {...catalog, account: {id: 'native-b', provider: 'qoder-cn', label: 'Account B'}, models: [${JSON.stringify(chat)}], maxConcurrency: 9, maxAccounts: 5} : catalog);
      if (url !== '${endpoint}/plugin/fetch' || init.method !== 'POST') throw new Error('unexpected fixture network');
      return Response.json({ envelope: JSON.parse(init.body), localAuthorization: headers.get('authorization') }, {status: 201});
    };\n`)
    child = Bun.spawn([process.execPath, '--preload', preload, fileURLToPath(new URL('../runtime/vendor/magpie/host.js', import.meta.url))],
      { cwd: directory, stdin: 'pipe', stdout: 'pipe', stderr: 'pipe' })
    stderr = new Response(child.stderr).text()
    pump = (async () => {
      let buffer = ''
      const decoder = new TextDecoder()
      for await (const part of child.stdout) {
        buffer += decoder.decode(part, { stream: true })
        let at
        while ((at = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, at); buffer = buffer.slice(at + 1)
          if (!line) continue
          const message = JSON.parse(line), call = pending.get(message.id)
          if (!call) continue
          if (message.event) call.events.push(message)
          else {
            pending.delete(message.id); clearTimeout(call.timer)
            if (message.error) call.reject(new Error(message.error.message))
            else call.resolve({ result: message.result, events: call.events })
          }
        }
      }
    })()
    let next = 0
    const rpc = (method, params) => new Promise((resolve, reject) => {
      const id = ++next
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`host ${method} timed out`)) }, 5000)
      pending.set(id, { resolve, reject, timer, events: [] })
      child.stdin.write(JSON.stringify({ id, method, params }) + '\n')
      child.stdin.flush()
    })
    const initialized = await rpc('init', { directory, authPath: join(directory, 'plugin-auth.json'), plugins: [{
      spec: 'loongpass-bridge', target: fileURLToPath(new URL('../runtime/bridge', import.meta.url)),
    }] })
    expect(initialized.result.plugins).toHaveLength(1)
    expect(initialized.result.plugins[0].error).toBeUndefined()
    const a = (await rpc('apiKey', { provider: 'loongpass', method: 0, key: 'synthetic-first', inputs: { endpoint, email: 'opaque-a' } })).result.account
    const b = (await rpc('apiKey', { provider: 'loongpass', method: 0, key: 'synthetic-second', inputs: { endpoint, email: 'opaque-b' } })).result.account
    const again = (await rpc('apiKey', { provider: 'loongpass', method: 0, key: 'synthetic-rotated', inputs: { endpoint, email: 'opaque-a' } })).result.account
    expect(again).toBe(a)
    expect(b).not.toBe(a)
    const row = (await rpc('providers', {})).result[0]
    expect(row.id).toBe('loongpass')
    expect(row.accounts).toHaveLength(2)
    expect(row.models).toEqual([ { ...anthropic, id: 'workbuddy/claude-native' }, { ...chat, id: 'workbuddy/chat/native' }, { ...chat, id: 'qoder-cn/chat/native' } ])
    expect(row.accounts.find(account => account.key === a).models).toEqual(['workbuddy/claude-native', 'workbuddy/chat/native'])
    expect(row.accounts.find(account => account.key === b).models).toEqual(['qoder-cn/chat/native'])
    // Magpie exposes provider-wide limits only; LoongPass enforces each
    // supplier/account's limits at the local service boundary instead.
    expect(row.maxConcurrency).toBe(0)
    expect(row.maxAccounts).toBe(0)
    expect(row.checkin).toBe(false)
    const fetched = await rpc('fetch', { provider: 'loongpass', account: a, model: 'workbuddy/claude-native', npm: anthropic.npm,
      url: 'https://native.invalid/anthropic/messages', method: 'POST', body: Buffer.from('{"model":"claude-api"}').toString('base64'),
      session: 'host-session', headers: { 'x-magpie-work-dir': '/fixture/project', 'x-magpie-fallback': '1' },
    })
    expect(fetched.events.find(e => e.event === 'head').status).toBe(201)
    const body = JSON.parse(Buffer.concat(fetched.events.filter(e => e.event === 'chunk').map(e => Buffer.from(e.data, 'base64'))).toString())
    expect(body.localAuthorization).toBe('Bearer synthetic-rotated')
    expect(body.envelope).toEqual({ model: 'workbuddy/claude-native', url: 'https://native.invalid/anthropic/messages', method: 'POST',
      headers: { 'x-magpie-work-dir': '/fixture/project', 'x-magpie-fallback': '1' }, body: 'eyJtb2RlbCI6ImNsYXVkZS1hcGkifQ==', session: 'host-session' })
  } finally {
    for (const call of pending.values()) clearTimeout(call.timer)
    if (child) { child.kill(); await child.exited; await pump; await stderr }
    await rm(directory, { recursive: true, force: true })
  }
}, 10000)
