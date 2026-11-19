import { expect, test } from 'bun:test'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { createInterface } from 'node:readline'

const runtime = resolve('runtime')
const now = Date.UTC(2026, 10, 20)
const day = 86_400_000
const accessAt = time => ['e30', Buffer.from(JSON.stringify({ iat: time / 1000 })).toString('base64url'), 'fixture'].join('.')

test('WorkBuddy CN preserves idle browser grants through the native renewal owner', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'loongpass-workbuddy-renewal-'))
  const authPath = join(directory, 'plugin-auth.json')
  const preload = join(directory, 'fixture.mjs')
  const stale = accessAt(now - 8 * day)
  const grants = {
    stale: { access: stale },
    opaque: { access: 'opaque', tokenObtainedAt: now - 7 * day },
    fresh: { access: accessAt(now - 6 * day) },
    soon: { access: accessAt(now - day), expires: now + 60_000 },
    desktop: { source: 'desktop', access: stale },
    noRefresh: { access: stale, refresh: '' },
    expiredRefresh: { access: stale, refreshExpiresAt: now - 1 },
    future: { access: accessAt(now + 2 * day) },
    malformed: { access: 'opaque' },
    key: { type: 'api', key: 'synthetic' },
  }
  const records = Object.fromEntries(Object.entries(grants).map(([id, grant]) => [
    'workbuddy#' + id,
    { type: 'oauth', uid: id, refresh: id, expires: now + 20 * day, ...grant },
  ]))
  await writeFile(authPath, JSON.stringify(records))
  // Both issuance and renewal are synthetic. A renewal deliberately returns
  // an access token whose iat still predates the latest successful exchange.
  await writeFile(preload, `
    import { appendFileSync } from 'node:fs'
    Date.now = () => ${now}
    globalThis.fetch = async (input, init) => {
      const { pathname } = new URL(input)
      const signIn = {
        '/v2/plugin/auth/state': { state: 'fixture', authUrl: 'https://fixture.invalid/authorize' },
        '/v2/plugin/auth/token': { accessToken: 'issued-opaque', refreshToken: 'issued-refresh', expiresAt: ${now + 30 * day} },
        '/v2/plugin/login/account': { uid: 'issued', type: 'personal' },
        '/v2/plugin/accounts': { accounts: [] },
      }
      if (Object.hasOwn(signIn, pathname)) return Response.json({ code: 0, data: signIn[pathname] })
      if (pathname !== '/v2/plugin/auth/token/refresh' || init.method !== 'POST')
        throw Error('Unexpected synthetic request: ' + pathname)
      const slot = new Headers(init.headers).get('X-Refresh-Token')
      appendFileSync('calls', slot + '\\n')
      return Response.json({ code: 0, data: {
        accessToken: ${JSON.stringify(stale)}, refreshToken: 'rotated-' + slot, expiresAt: ${now + 28 * day}
      } })
    }
  `)
  const child = spawn(process.execPath, ['--preload', preload, join(runtime, 'vendor/magpie/host.js')], {
    cwd: directory, env: { ...process.env, HOME: directory, USERPROFILE: directory }, stdio: ['pipe', 'pipe', 'pipe'],
  })
  const exited = once(child, 'exit')
  const output = createInterface({ input: child.stdout })[Symbol.asyncIterator]()
  let sequence = 0
  async function rpc(method, params) {
    const id = ++sequence
    child.stdin.write(JSON.stringify({ id, method, params }) + '\n')
    for (;;) {
      const line = await output.next()
      if (line.done) throw Error('Native host exited before its reply')
      const reply = JSON.parse(line.value)
      if (reply.id !== id) continue
      if (reply.error) throw Error(reply.error.message)
      return reply.result
    }
  }
  const maintain = id => rpc('keepSignedIn', { provider: 'workbuddy', account: 'workbuddy#' + id })
  try {
    const initialized = await rpc('init', {
      authPath, directory, plugins: [{ spec: 'workbuddy', target: join(runtime, 'vendor/plugins/workbuddy/index.mjs') }],
    })
    expect(initialized.plugins[0].error).toBeUndefined()
    for (const id of ['stale', 'opaque', 'soon']) {
      expect(await maintain(id), id).toMatchObject({ due: true, renewed: true })
      expect(await maintain(id), id).toMatchObject({ due: false, renewed: false })
    }
    for (const id of ['fresh', 'desktop', 'noRefresh', 'expiredRefresh', 'future', 'malformed', 'key']) {
      expect(await maintain(id), id).toMatchObject({ due: false, renewed: false })
    }
    expect((await readFile(join(directory, 'calls'), 'utf8')).trim().split('\n')).toEqual(['stale', 'opaque', 'soon'])
    const started = await rpc('authorize', { provider: 'workbuddy', method: 0 })
    const issued = await rpc('callback', { session: started.session })
    expect(issued.ok).toBe(true)
    const saved = JSON.parse(await readFile(authPath, 'utf8'))
    expect(saved[issued.account]).toMatchObject({ access: 'issued-opaque', tokenObtainedAt: now, expires: now + 30 * day })
    expect(saved['workbuddy#opaque']).toMatchObject({ tokenObtainedAt: now, expires: now + 28 * day })
    expect(saved['workbuddy#desktop']).toEqual(records['workbuddy#desktop'])
  } finally {
    child.stdin.end()
    const timer = setTimeout(() => child.kill(), 1500)
    await exited
    clearTimeout(timer)
    await rm(directory, { recursive: true, force: true })
  }
})
