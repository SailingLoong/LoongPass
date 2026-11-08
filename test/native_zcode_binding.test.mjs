// The public native authorization hooks and host are exercised from private
// copies. No installed client, user's home, credentials or network is read.
import { afterAll, afterEach, beforeAll, expect, test } from 'bun:test';
import { spawn } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath, pathToFileURL } from 'node:url';

const runtime = process.env.LOONGPASS_BINDING_RUNTIME ?? resolve(dirname(fileURLToPath(import.meta.url)), '../runtime');
const device = '11111111-2222-4333-8444-555555555555';
const nextDevice = '22222222-2222-4333-8444-555555555555';
const jwt = 'e30.' + Buffer.from(JSON.stringify({ exp: 4102444800 })).toString('base64url') + '.fake';
const grant = (team = false) => ({
  type: 'oauth', uid: 'official-a', accountId: 'bigmodel:official-a' + (team ? ' (team)' : ''), access: jwt, expires: 0,
  refresh: JSON.stringify({ site: 'bigmodel', jwt, device, ...(team ? { org: 'org', project: 'project' } : {}) }),
});
const realFetch = globalThis.fetch;
const noNetwork = async () => { throw new Error('Network forbidden'); };
let temporary, ZCodeAuthPlugin;
beforeAll(async () => {
  temporary = await mkdtemp(join(tmpdir(), 'loongpass-native-binding-'));
  await cp(join(runtime, 'vendor/plugins/zcode'), join(temporary, 'zcode'), { recursive: true });
  ({ ZCodeAuthPlugin } = await import(pathToFileURL(join(temporary, 'zcode/index.mjs')).href));
  globalThis.fetch = noNetwork;
});
afterEach(() => { globalThis.fetch = noNetwork; });
afterAll(async () => {
  globalThis.fetch = realFetch;
  await rm(temporary, { recursive: true, force: true });
});

function official({ uid = 'official-a', team = false } = {}) {
  const requests = [];
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(String(input));
    requests.push({ url, headers: new Headers(init.headers), body: init.body });
    const answer = data => Response.json({ code: 0, data });
    if (url.hostname === 'zcode.z.ai') {
      if (url.pathname === '/api/v1/oauth/cli/init') {
        expect(JSON.parse(init.body).provider).toBe('bigmodel');
        return answer({ flow_id: 'synthetic', authorize_url: 'https://bigmodel.cn/login', poll_interval_sec: 1 });
      }
      if (url.pathname === '/api/v1/oauth/cli/poll/synthetic') {
        return answer({ status: 'ready', user: { user_id: uid }, token: jwt, bigmodel: { access_token: 'synthetic-biz' } });
      }
      if (url.pathname === '/api/v1/zcode-plan/billing/balance') return answer({ plans: [{ plan_id: 'gift', status: 'active', name: 'Start Plan' }], balances: [] });
    }
    if (url.hostname === 'open.bigmodel.cn' && url.pathname === '/api/biz/subscription/list') return answer([{ status: 'VALID', productName: 'GLM Coding Pro' }]);
    if (url.hostname !== 'bigmodel.cn') return noNetwork();
    if (url.pathname === '/api/auth/z/login') return answer({ access_token: 'synthetic-biz' });
    if (url.pathname === '/api/biz/customer/getCustomerInfo') return answer({ organizations: team ? [{ organizationId: 'org', projects: [{ projectId: 'project', projectType: 2 }] }] : [] });
    if (url.pathname.endsWith('/api_keys')) return answer([{ apiKey: 'fake-key', name: 'zcode-team-api-key', keyType: 2 }]);
    if (url.pathname.endsWith('/api_keys/copy/fake-key')) return answer({ secretKey: 'fake-secret' });
    if (url.pathname === '/api/biz/team/subscribe/product/querySubscribeDetail') return answer({ status: 'EFFECTIVE', memberGrantStatus: 'VALID', productName: 'GLM Coding Team' });
    return noNetwork();
  };
  return requests;
}

for (const team of [false, true]) {
  test(`native reauthorization retains the saved ${team ? 'team' : 'personal'} device and profile`, async () => {
    const requests = official({ team });
    const hooks = await ZCodeAuthPlugin();
    const pending = await hooks.auth.reauthorize(async () => grant(team), { expectedUid: 'official-a', expectedRealm: 'bigmodel' });
    const result = await pending.callback();
    expect(result.type).toBe('success');
    expect(result.uid).toBe('official-a');
    expect(result.accountId).toBe(grant(team).accountId);
    expect(JSON.parse(result.refresh).device).toBe(device);
    expect(requests.filter(r => r.url.pathname.includes('/oauth/cli/')).map(r => r.headers.get('x-device-mid'))).toEqual([device, device]);
  });
}

test('explicit native rebind freezes the chosen device for init, poll and returned grant', async () => {
  const requests = official();
  const hooks = await ZCodeAuthPlugin();
  const context = { device: nextDevice, expectedUid: 'official-a', expectedRealm: 'bigmodel' };
  const pending = await hooks.auth.reauthorize(async () => grant(), context);
  context.device = device;
  const result = await pending.callback();
  expect(result.type).toBe('success');
  expect(JSON.parse(result.refresh).device).toBe(nextDevice);
  expect(requests.filter(r => r.url.pathname.includes('/oauth/cli/')).map(r => r.headers.get('x-device-mid'))).toEqual([nextDevice, nextDevice]);
});

test('a different official UID cannot produce a replacement grant or query its paid entitlement', async () => {
  const requests = official({ uid: 'other-account' });
  const hooks = await ZCodeAuthPlugin();
  const pending = await hooks.auth.reauthorize(async () => grant(), { device: nextDevice });
  expect((await pending.callback()).type).toBe('failed');
  expect(requests.map(r => r.url.pathname)).toEqual(['/api/v1/oauth/cli/init', '/api/v1/oauth/cli/poll/synthetic']);
});

test('stale expected identity, realm and malformed selected device fail before any request', async () => {
  const hooks = await ZCodeAuthPlugin();
  for (const context of [{ expectedUid: 'other' }, { expectedRealm: 'zai' }, { device: 'invalid' }]) {
    await expect(hooks.auth.reauthorize(async () => grant(), context)).rejects.toThrow();
  }
});

test('reward context is native client metadata bound to the verified saved grant', async () => {
  const hooks = await ZCodeAuthPlugin();
  expect(await hooks.auth.rewardContext(async () => grant())).toEqual({
    version: '3.17.2', platform: `${process.platform}-${process.arch}`, deviceMid: device,
    language: /^zh\b/i.test(Intl.DateTimeFormat().resolvedOptions().locale) ? 'zh-CN' : 'en-US',
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
  });
  await expect(hooks.auth.rewardContext(async () => ({ ...grant(), uid: '' }))).rejects.toThrow();
  await expect(hooks.auth.rewardContext(async () => ({ type: 'api', key: 'synthetic' }))).rejects.toThrow();
});

async function host(run) {
  const directory = await mkdtemp(join(temporary, 'host-'));
  const fixture = join(directory, 'fixture.mjs');
  await writeFile(fixture, `export const Synthetic = async () => ({
    config: async c => { c.provider = { synthetic: { name: 'Synthetic', models: {} } }; },
    auth: { provider: 'synthetic', methods: [{ type: 'oauth', label: 'New', authorize: async inputs => {
      if (inputs !== undefined) throw new Error('no-prompt behavior changed');
      return {method:'auto', callback:async()=>({type:'success',access:'fresh',refresh:'fresh',expires:0,uid:'official-a',accountId:'official-a'})};
    }}],
    rewardContext: async getAuth => ({ deviceMid: (await getAuth()).device }),
    reauthorize: async (getAuth, context) => {
      const auth = await getAuth();
      if (context.expectedUid !== auth.uid) throw new Error('identity mismatch');
      return {method:'auto', callback:async()=>({...auth,type:'success',device:context.device??auth.device})};
    },
  }});`);
  const entry = join(directory, 'entry.mjs');
  await writeFile(entry, `globalThis.fetch = async()=>{throw new Error('Network forbidden')}; await import(${JSON.stringify(pathToFileURL(join(runtime, 'vendor/magpie/host.js')).href)});`);
  const child = spawn(process.execPath, [entry], { cwd: directory, env: { ...process.env, HOME: directory, USERPROFILE: directory }, stdio: ['pipe', 'pipe', 'pipe'] });
  const pending = new Map(), lines = createInterface({ input: child.stdout });
  let next = 0, errors = '';
  child.stderr.on('data', data => { errors += data; });
  lines.on('line', line => {
    const message = JSON.parse(line), waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    clearTimeout(waiter.timer);
    if (message.error) waiter.reject(new Error(message.error.message)); else waiter.resolve(message.result);
  });
  const exited = new Promise(resolve => child.once('exit', resolve));
  const rpc = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++next;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timed out`)); }, 4000);
    pending.set(id, { resolve, reject, timer });
    child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
  });
  const authPath = join(directory, 'plugin-auth.json');
  try {
    await rpc('init', { directory, authPath, plugins: [{ spec: 'synthetic', target: fixture }] });
    await run({ rpc, saved: async () => JSON.parse(await readFile(authPath, 'utf8')) });
  } finally {
    child.stdin.end();
    const kill = setTimeout(() => child.kill(), 1000);
    await exited;
    clearTimeout(kill);
    lines.close();
    expect(errors).toBe('');
  }
}

test('host advertises declared capabilities, scopes reward context, and preserves default no-prompt login', async () => {
  await host(async ({ rpc, saved }) => {
    const rows = await rpc('providers', { off: ['synthetic'] });
    expect(rows[0]).toMatchObject({ reauthorize: true, rewardContext: true });
    const started = await rpc('authorize', { provider: 'synthetic', method: 0, account: 'new', inputs: { ignored: 'kept native' } });
    const done = await rpc('callback', { session: started.session });
    await rpc('import', { provider: 'synthetic', key: done.account, auth: { ...(await saved())[done.account], device } });
    expect(await rpc('rewardContext', { provider: 'synthetic', account: done.account })).toEqual({ deviceMid: device });
    const reauth = await rpc('authorize', { provider: 'synthetic', account: done.account, context: { expectedUid: 'official-a', device: nextDevice } });
    expect((await rpc('callback', { session: reauth.session })).account).toBe(done.account);
    expect((await saved())[done.account].device).toBe(nextDevice);
  });
});

for (const change of ['remove', 'reauthorize']) {
  test(`targeted native callback cannot overwrite a target changed by ${change}`, async () => {
    await host(async ({ rpc, saved }) => {
      const key = 'synthetic#existing';
      const original = { type: 'oauth', uid: 'official-a', accountId: 'official-a', access: 'old', refresh: 'old', expires: 0, device };
      await rpc('import', { provider: 'synthetic', key, auth: original });
      const started = await rpc('authorize', { provider: 'synthetic', account: key, context: { expectedUid: 'official-a', device: nextDevice } });
      if (change === 'remove') await rpc('signOut', { provider: 'synthetic', account: key });
      else await rpc('import', { provider: 'synthetic', key, auth: { ...original, access: 'newer', refresh: 'newer' } });
      const before = await saved();
      await expect(rpc('callback', { session: started.session })).rejects.toThrow();
      expect(await saved()).toEqual(before);
    });
  });
}

test('explicit target reauthorization keeps both existing native profile keys', async () => {
  await host(async ({ rpc, saved }) => {
    const original = { type: 'oauth', uid: 'official-a', accountId: 'official-a', access: 'old', refresh: 'old', expires: 0, device };
    for (const key of ['synthetic#personal', 'synthetic#team']) {
      await rpc('import', { provider: 'synthetic', key, auth: original });
    }
    const started = await rpc('authorize', { provider: 'synthetic', account: 'synthetic#team', context: { expectedUid: 'official-a', device: nextDevice } });
    expect((await rpc('callback', { session: started.session })).account).toBe('synthetic#team');
    expect(Object.keys(await saved()).sort()).toEqual(['synthetic#personal', 'synthetic#team']);
    expect((await saved())['synthetic#personal']).toEqual(original);
  });
});
