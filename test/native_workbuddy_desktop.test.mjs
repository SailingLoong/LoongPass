import { expect, test } from 'bun:test'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const modulePath = process.env.LOONGPASS_WORKBUDDY_MODULE || fileURLToPath(new URL('../runtime/vendor/plugins/workbuddy/index.mjs', import.meta.url))

// The real public hooks read only a child process's synthetic desktop profile.
// Fetch is replaced before import, so no account or request reaches the user.
async function desktop(scenario = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'loongpass-wb-desktop-test-'))
  try {
    const runner = join(directory, 'run.mjs')
    await writeFile(runner, `
      import {mkdirSync, writeFileSync} from 'node:fs';
      import {homedir} from 'node:os';
      import {join} from 'node:path';
      import {pathToFileURL} from 'node:url';
      const scenario = ${JSON.stringify(scenario)}, calls = [];
      let saved;
      const home = homedir();
      const base = process.platform === 'darwin' ? join(home, 'Library', 'Application Support', 'CodeBuddyExtension')
        : process.platform === 'win32' ? join(home, 'AppData', 'Local', 'CodeBuddyExtension')
        : join(home, '.local', 'share', 'CodeBuddyExtension');
      const dir = join(base, 'Data', 'Public', 'auth');
      mkdirSync(dir, {recursive: true});
      const initial = {uid: 'official-a', domain: 'www.workbuddy.cn', token: 'synthetic-a', expires: 4102444800000, ...scenario.initial};
      const save = a => writeFileSync(join(dir, 'workbuddy-desktop.info'), JSON.stringify({
        account: {uid: a.uid, nickname: 'Synthetic desktop'},
        auth: {domain: a.domain, accessToken: a.token, refreshToken: '', expiresAt: a.expires},
      }));
      save(initial);
      globalThis.fetch = async (input, init = {}) => {
        const url = new URL(String(input)), headers = new Headers(init.headers);
        if (url.origin !== 'https://copilot.tencent.com') throw Error('Unexpected fixture origin');
        calls.push({path: url.pathname, token: headers.get('authorization'), domain: headers.get('x-domain'), uid: headers.get('x-user-id')});
        if (scenario.refused && calls.length === 1) {
          save({...initial, ...scenario.next});
          if (scenario.slot) Object.assign(saved, scenario.slot);
          return Response.json({code: 401, message: 'synthetic refused'}, {status: 401, headers: {'www-authenticate': 'Bearer error="invalid_token"'}});
        }
        if (url.pathname === '/v1/messages') return Response.json({type: 'message', content: [{type: 'text', text: 'ok'}], stop_reason: 'end_turn'});
        if (url.pathname === '/v2/billing/meter/checkin-activity-status') return Response.json({code: 0, data: {active: true, today_checked_in: false}});
        if (url.pathname.startsWith('/billing/meter/')) return Response.json({code: 0, data: {}});
        throw Error('Unexpected fixture path: ' + url.pathname);
      };
      const {WorkBuddyAuthPlugin} = await import(pathToFileURL(process.argv[2]).href);
      const hooks = await WorkBuddyAuthPlugin({client: {auth: {set: async () => { throw Error('Desktop credential must not be copied'); }}}});
      const grant = await (await hooks.auth.methods[1].authorize()).callback();
      saved = {...grant, type: 'oauth', domain: initial.domain};
      if (scenario.legacy) delete saved.domain;
      if (scenario.browser) Object.assign(saved, {source: undefined, access: 'synthetic-browser', domain: initial.domain});
      if (scenario.next && !scenario.refused) save({...initial, ...scenario.next});
      let result, error;
      try {
        if (scenario.operation === 'signIn') result = grant;
        else if (scenario.operation === 'usage') result = await hooks.auth.usage(async () => structuredClone(saved));
        else if (scenario.operation === 'status') result = await hooks.auth.checkinStatus(async () => structuredClone(saved));
        else {
          const loader = await hooks.auth.loader(async () => structuredClone(saved));
          const fetch = () => loader.fetch('https://copilot.tencent.com/v1/messages', {
            method: 'POST', body: JSON.stringify({model: 'claude-sonnet-4-5', messages: [{role: 'user', content: 'synthetic'}], max_tokens: 16}),
          });
          const response = await fetch();
          result = {status: response.status, body: await response.text()};
          if (scenario.secondRealm) {
            const other = {...initial, ...scenario.secondRealm};
            save(other);
            const again = await (await hooks.auth.methods[1].authorize()).callback();
            Object.assign(saved, again, {type: 'oauth', domain: other.domain});
            const second = await fetch();
            result.secondStatus = second.status;
          }
        }
      } catch (e) { error = e.message; }
      process.stdout.write(JSON.stringify({grant, result, error, calls}));
    `)
    const child = Bun.spawn([process.execPath, runner, modulePath], {
      cwd: directory, env: {...process.env, HOME: directory, USERPROFILE: directory}, stdout: 'pipe', stderr: 'pipe',
    })
    const [output, error, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited])
    expect(code, error).toBe(0)
    return JSON.parse(output)
  } finally { await rm(directory, {recursive: true, force: true}) }
}

test('public desktop sign-in stores exact identity and domain, without copying its access/refresh token', async () => {
  const read = await desktop({operation: 'signIn'})
  expect(read.result).toMatchObject({type: 'success', uid: 'official-a', domain: 'www.workbuddy.cn', source: 'desktop', access: '', refresh: ''})
  expect(JSON.stringify(read.grant)).not.toContain('synthetic-a')
  expect(read.calls).toHaveLength(0)
})

for (const initial of [{domain: ''}, {domain: null}, {uid: {}}, {uid: 12}]) {
  test(`unverified desktop identity cannot authorize: ${JSON.stringify(initial)}`, async () => {
    const read = await desktop({operation: 'signIn', initial})
    expect(read.result.type).toBe('failed')
    expect(read.calls).toHaveLength(0)
  })
}

for (const operation of ['fetch', 'usage', 'status']) {
  for (const next of [{uid: 'official-b', token: 'synthetic-b'}, {domain: 'www.codebuddy.cn', token: 'synthetic-b'}]) {
    test(`${operation} rejects a changed desktop ${next.uid ? 'UID' : 'domain'} before any request`, async () => {
      const read = await desktop({operation, next})
      expect(read.error || read.result?.error).toContain('desktop account changed')
      expect(read.calls).toHaveLength(0)
    })
  }
}

test('legacy desktop grant without a bound domain requires sign-in again', async () => {
  const read = await desktop({legacy: true})
  expect(read.error).toContain('desktop account changed')
  expect(read.calls).toHaveLength(0)
})

test('same desktop identity reads its newly rotated token and still serves inference', async () => {
  const read = await desktop({next: {token: 'synthetic-rotated'}})
  expect(read.error).toBeUndefined()
  expect(read.result.status).toBe(200)
  expect(read.calls.map(c => c.token)).toEqual(['Bearer synthetic-rotated'])
})

for (const operation of ['fetch', 'usage']) {
  for (const next of [{uid: 'official-b', token: 'synthetic-b'}, {domain: 'www.codebuddy.cn', token: 'synthetic-b'}]) {
    test(`${operation} never follows another ${next.uid ? 'UID' : 'domain'} during native 401 recovery`, async () => {
      const read = await desktop({operation, refused: true, next})
      expect(read.calls).toHaveLength(1)
      expect(read.calls[0].token).toBe('Bearer synthetic-a')
      if (operation === 'fetch') expect(read.result.status).toBe(401)
      else expect(read.result.error).toContain('desktop account changed')
    })
  }
}

test('native 401 recovery still retries with a rotated token for the same bound desktop identity', async () => {
  const read = await desktop({refused: true, next: {token: 'synthetic-rotated'}})
  expect(read.error).toBeUndefined()
  expect(read.result.status).toBe(200)
  expect(read.calls.map(c => c.token)).toEqual(['Bearer synthetic-a', 'Bearer synthetic-rotated'])
})

test('held desktop tokens are isolated by native domain even for the same UID', async () => {
  const read = await desktop({secondRealm: {domain: 'www.codebuddy.cn', token: 'synthetic-other-domain', expires: 4070908800000}})
  expect(read.error).toBeUndefined()
  expect(read.result.secondStatus).toBe(200)
  expect(read.calls.map(c => [c.domain, c.token])).toEqual([
    ['www.workbuddy.cn', 'Bearer synthetic-a'], ['www.codebuddy.cn', 'Bearer synthetic-other-domain'],
  ])
})

test('browser grant remains independent of the desktop account and retains its own token', async () => {
  const read = await desktop({browser: true, next: {uid: 'official-b', token: 'synthetic-b'}})
  expect(read.error).toBeUndefined()
  expect(read.result.status).toBe(200)
  expect(read.calls.map(c => c.token)).toEqual(['Bearer synthetic-browser'])
})

for (const slot of [
  {uid: 'official-b', access: 'synthetic-b'},
  {domain: 'www.codebuddy.cn', access: 'synthetic-b'},
]) {
  test(`browser recovery rejects replacement native ${slot.uid ? 'UID' : 'domain'} before using its token`, async () => {
    const read = await desktop({browser: true, refused: true, slot})
    expect(read.calls.map(c => c.token)).toEqual(['Bearer synthetic-browser'])
    expect(read.error).toContain('account changed')
  })
}

test('browser recovery still accepts a native token rotation for the same identity', async () => {
  const read = await desktop({browser: true, refused: true, slot: {access: 'synthetic-browser-rotated'}})
  expect(read.error).toBeUndefined()
  expect(read.result.status).toBe(200)
  expect(read.calls.map(c => c.token)).toEqual(['Bearer synthetic-browser', 'Bearer synthetic-browser-rotated'])
})
