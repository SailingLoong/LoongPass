// Run with the pinned Bun. LOONGPASS_IDENTITY_RUNTIME can select a temporary
// patched runtime; all package imports, host data and desktop credentials are
// copied/generated under a temporary directory. No real account or network.
import { afterAll, afterEach, beforeAll, expect, test } from 'bun:test';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath, pathToFileURL } from 'node:url';

const runtime = process.env.LOONGPASS_IDENTITY_RUNTIME ?? resolve(dirname(fileURLToPath(import.meta.url)), '../runtime');
const realFetch = globalThis.fetch;
let temporary, packages, LoomyAuthPlugin, ZCodeAuthPlugin;
const noNetwork = async () => { throw new Error('Network is forbidden in native identity tests'); };
beforeAll(async () => {
  temporary = await mkdtemp(join(tmpdir(), 'loongpass-native-identity-'));
  packages = join(temporary, 'plugins');
  await mkdir(packages);
  for (const name of ['loomy', 'zcode']) {
    await cp(join(runtime, 'vendor/plugins', name), join(packages, name), { recursive: true });
  }
  ({ LoomyAuthPlugin } = await import(pathToFileURL(join(packages, 'loomy/index.mjs')).href));
  ({ ZCodeAuthPlugin } = await import(pathToFileURL(join(packages, 'zcode/index.mjs')).href));
  globalThis.fetch = noNetwork;
});
afterEach(() => { globalThis.fetch = noNetwork; });
afterAll(async () => {
  globalThis.fetch = realFetch;
  if (temporary) await rm(temporary, { recursive: true, force: true });
});

async function loomySignIn(phone, uid) {
  globalThis.fetch = async (input, init) => {
    const url = new URL(String(input));
    if (url.hostname !== 'account.xfinfr.com' || init.method !== 'POST') return noNetwork();
    const body = JSON.parse(init.body);
    expect(body.param.phone).toBe(phone);
    if (url.pathname === '/login/phone/sendMsgCode') return Response.json({ code: '000000', data: { msgid: 'fake-message' } });
    if (url.pathname === '/login/phone/checkCode') {
      expect(body.param.msgid).toBe('fake-message');
      expect(body.param.mcode).toBe('123456');
      return Response.json({ code: '000000', data: { session: `fake-session-${phone}`, userid: uid } });
    }
    return noNetwork();
  };
  const hooks = await LoomyAuthPlugin();
  return (await hooks.auth.methods[0].authorize({ phone })).callback('123456');
}

const jwt = 'e30.' + Buffer.from(JSON.stringify({ exp: 4102444800 })).toString('base64url') + '.fake';
async function zcodeSignIn(site, { user = { user_id: 'shared-uid', email: 'same@example.invalid' }, paid = false, team = false } = {}) {
  const api = site === 'bigmodel' ? 'bigmodel.cn' : 'api.z.ai';
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(String(input));
    const answer = (data) => Response.json({ code: 0, data });
    if (url.hostname === 'zcode.z.ai') {
      if (url.pathname === '/api/v1/oauth/cli/init') {
        expect(JSON.parse(init.body).provider).toBe(site);
        return answer({ flow_id: 'synthetic', authorize_url: `https://${site === 'bigmodel' ? 'bigmodel.cn' : 'z.ai'}/login`, poll_interval_sec: 1 });
      }
      if (url.pathname === '/api/v1/oauth/cli/poll/synthetic') return answer({ status: 'ready', user, token: jwt, [site]: { access_token: 'fake-vendor-token' } });
      if (url.pathname === '/api/v1/zcode-plan/billing/balance') return answer({ plans: [{ plan_id: 'gift', status: 'active', name: 'Start Plan' }], balances: [] });
    }
    if (url.pathname === '/api/biz/subscription/list' && url.hostname === (site === 'bigmodel' ? 'open.bigmodel.cn' : api)) return answer([{ status: 'VALID', productName: 'GLM Coding Pro' }]);
    if (url.hostname !== api) return noNetwork();
    if (url.pathname === '/api/auth/z/login') return answer({ access_token: 'fake-biz-token' });
    if (url.pathname === '/api/biz/customer/getCustomerInfo') return answer({ organizations: paid || team ? [{ organizationId: 'org', projects: [{ projectId: 'project', projectType: team ? 2 : 1 }] }] : [] });
    if (url.pathname.endsWith('/api_keys')) return answer([{ apiKey: 'fake-key', name: team ? 'zcode-team-api-key' : 'zcode-api-key', keyType: team ? 2 : 1 }]);
    if (url.pathname.endsWith('/api_keys/copy/fake-key')) return answer({ secretKey: 'fake-secret' });
    if (url.pathname === '/api/biz/team/subscribe/product/querySubscribeDetail') return answer({ status: 'EFFECTIVE', memberGrantStatus: 'VALID', productName: 'GLM Coding Team' });
    return noNetwork();
  };
  const hooks = await ZCodeAuthPlugin();
  const method = hooks.auth.methods[team ? 2 : site === 'bigmodel' ? 1 : 0];
  return (await method.authorize({ site })).callback();
}

test('Loomy SMS stores official identity separately from a colliding masked label', async () => {
  const first = await loomySignIn('13800001234', 'official-a');
  const second = await loomySignIn('13899991234', 'official-b');
  expect(first).toMatchObject({ type: 'success', accountId: 'official-a', uid: 'official-a', userId: 'official-a', name: '138****1234' });
  expect(second).toMatchObject({ type: 'success', accountId: 'official-b', uid: 'official-b', userId: 'official-b', name: '138****1234' });
});

test('Loomy cannot save an SMS session with missing or malformed official UID', async () => {
  for (const uid of [undefined, '', '  ', { unexpected: 'object' }, 9007199254740992]) {
    expect((await loomySignIn('13800001234', uid)).type).toBe('failed');
  }
});

test('Loomy preserves a safe numeric official UID as an exact string', async () => {
  expect(await loomySignIn('13800001234', 123456789)).toMatchObject({
    type: 'success', accountId: '123456789', uid: '123456789', userId: '123456789',
  });
});

test('Loomy manual session fails instead of assigning an unverified shared identity', async () => {
  const hooks = await LoomyAuthPlugin();
  const pending = await hooks.auth.methods[1].authorize({ session: 'fake-manual-session' });
  const result = pending.callback ? await pending.callback() : pending;
  expect(result.type).toBe('failed');
  expect(result.error).toBeTruthy();
});

for (const site of ['zai', 'bigmodel']) {
  for (const paid of [false, true]) {
    test(`ZCode ${site} ${paid ? 'paid-key' : 'JWT-only'} authorization uses its region and official UID`, async () => {
      const result = await zcodeSignIn(site, { paid });
      expect(result).toMatchObject({ type: 'success', uid: 'shared-uid', accountId: `${site}:shared-uid`, name: 'same@example.invalid' });
      expect(JSON.parse(result.refresh).site).toBe(site);
      expect(result.access).toBe(paid ? 'fake-key.fake-secret' : jwt);
    });
  }
}

test('ZCode missing official UID is rejected even when email and a valid gift are present', async () => {
  const result = await zcodeSignIn('bigmodel', { user: { email: 'same@example.invalid' } });
  expect(result.type).toBe('failed');
});

test('ZCode keeps its separate team entitlement under the canonical regional identity', async () => {
  const result = await zcodeSignIn('bigmodel', { team: true });
  expect(result).toMatchObject({ type: 'success', accountId: 'bigmodel:shared-uid (team)', uid: 'shared-uid', name: 'same@example.invalid (team)' });
});

test('ZCode raw API-key loading consumes its saved region without inventing an official UID', async () => {
  const hooks = await ZCodeAuthPlugin();
  const zai = await hooks.auth.loader(async () => ({ type: 'api', key: 'same.secret', metadata: { site: 'zai' } }));
  const bigmodel = await hooks.auth.loader(async () => ({ type: 'api', key: 'same.secret', metadata: { site: 'bigmodel' } }));
  expect(zai.baseURL).toBe('https://api.z.ai/api/anthropic/v1');
  expect(bigmodel.baseURL).toBe('https://open.bigmodel.cn/api/anthropic/v1');
});

// The desktop hook is tested in a child with an isolated home and synthetic
// encrypted credentials. No native plugin ever reads the user's home here.
async function desktop(steps) {
  const directory = await mkdtemp(join(temporary, 'desktop-'));
  const runner = join(directory, 'run.mjs');
  await writeFile(runner, `
    import { createCipheriv, createHash, randomBytes } from 'node:crypto';
    import { mkdirSync, writeFileSync } from 'node:fs';
    import { homedir } from 'node:os';
    import { join } from 'node:path';
    import { pathToFileURL } from 'node:url';
    globalThis.fetch = async () => { throw new Error('Network forbidden'); };
    const { ZCodeAuthPlugin } = await import(pathToFileURL(process.argv[2]).href);
    const hooks = await ZCodeAuthPlugin();
    const dir = join(homedir(), '.zcode/v2');
    mkdirSync(dir, { recursive: true });
    const seal = (value) => {
      const iv = randomBytes(12);
      const cipher = createCipheriv('aes-256-gcm', createHash('sha256').update('identity-fixture').digest(), iv);
      const data = Buffer.concat([cipher.update(value), cipher.final()]);
      return 'enc:v1:' + [iv, cipher.getAuthTag(), data].map(b => b.toString('base64url')).join('.');
    };
    const results = [];
    let auth;
    for (const step of JSON.parse(await Bun.stdin.text())) {
      writeFileSync(join(dir, 'credentials.json'), JSON.stringify(Object.fromEntries(Object.entries(step.credentials).map(([k, v]) => [k, step.v2 ? 'enc:v2:os:synthetic' : seal(v)]))));
      writeFileSync(join(dir, 'setting.json'), JSON.stringify(step.settings ?? {}));
      if (!auth) {
        const method = hooks.auth.methods.find(m => m.label === "ZCode app's sign-in");
        const result = await (await method.authorize()).callback();
        results.push(result);
        if (result.type === 'success') auth = { ...result, type: 'oauth' };
      } else {
        const result = await hooks.auth.loader(async () => auth, { id: 'zcode' });
        results.push({ apiKey: result.apiKey, baseURL: result.baseURL });
      }
    }
    process.stdout.write(JSON.stringify(results));
  `);
  const child = Bun.spawn([process.execPath, runner, join(packages, 'zcode/index.mjs')], {
    cwd: directory, env: { ...process.env, HOME: directory, USERPROFILE: directory, ZCODE_CREDENTIAL_SECRET: 'identity-fixture' },
    stdin: new TextEncoder().encode(JSON.stringify(steps)), stdout: 'pipe', stderr: 'pipe',
  });
  const [output, errors, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  expect(errors).toBe('');
  expect(code).toBe(0);
  return JSON.parse(output);
}

function desktopState(site, { uid = 'shared-uid', email = 'same@example.invalid', key = 'initial.secret', field = 'user_id' } = {}) {
  return {
    settings: { providerFamilyDomain: site },
    credentials: {
      zcodejwttoken: jwt,
      [`oauth:${site}:user_info`]: JSON.stringify({ [field]: uid, email }),
      ...(key ? { [`account-provider:coding-plan:account:${site}-individual-coding-plan:account:synthetic:api-key`]: key } : {}),
    },
  };
}

test('ZCode desktop takes the official profile belonging to the selected paid key region', async () => {
  const state = desktopState('bigmodel', { field: 'id' });
  state.credentials['oauth:zai:user_info'] = JSON.stringify({ user_id: 'wrong-region', email: 'wrong@example.invalid' });
  const [result] = await desktop([state]);
  expect(result).toMatchObject({ type: 'success', uid: 'shared-uid', accountId: 'bigmodel:shared-uid', name: 'same@example.invalid' });
});

test('ZCode desktop JWT-only sign-in retains the selected region', async () => {
  const [result] = await desktop([desktopState('bigmodel', { key: '' })]);
  expect(result).toMatchObject({ type: 'success', uid: 'shared-uid', accountId: 'bigmodel:shared-uid' });
  expect(JSON.parse(result.refresh).site).toBe('bigmodel');
});

test('ZCode system-encrypted desktop credentials explain browser authorization without reading the OS key store', async () => {
  const state = { ...desktopState('bigmodel'), v2: true };
  const [result] = await desktop([state]);
  expect(result.type).toBe('failed');
  expect(result.error).toContain('system-encrypted');
  expect(result.error).toContain('browser');
  expect(await desktop([desktopState('bigmodel'), state])).toMatchObject([
    {type:'success'}, {apiKey:'initial.secret',baseURL:'https://open.bigmodel.cn/api/anthropic/v1'},
  ]);
});

test('ZCode desktop rejects a profile without official UID', async () => {
  const state = desktopState('bigmodel');
  state.credentials['oauth:bigmodel:user_info'] = JSON.stringify({ email: 'same@example.invalid' });
  expect((await desktop([state]))[0].type).toBe('failed');
});

test('ZCode desktop JWT-only sign-in rejects an unspecified region', async () => {
  const state = desktopState('bigmodel', { key: '' });
  state.settings = {};
  expect((await desktop([state]))[0].type).toBe('failed');
});

test('ZCode desktop follows same-account renewed credentials after a label change and never the other region', async () => {
  const results = await desktop([
    desktopState('bigmodel'),
    desktopState('bigmodel', { key: 'renewed.secret', email: 'renamed@example.invalid' }),
    desktopState('zai', { key: 'foreign.secret', email: 'renamed@example.invalid' }),
  ]);
  expect(results[1]).toEqual({ apiKey: 'renewed.secret', baseURL: 'https://open.bigmodel.cn/api/anthropic/v1' });
  expect(results[2]).toEqual({ apiKey: 'initial.secret', baseURL: 'https://open.bigmodel.cn/api/anthropic/v1' });
});

async function nativeHost(run) {
  const directory = await mkdtemp(join(temporary, 'host-'));
  const fixture = join(directory, 'auth.mjs');
  await writeFile(fixture, `export const Synthetic = async (_, options) => ({ auth: { provider: options.provider, methods: [{ type: 'oauth', label: 'Synthetic', prompts: [{type: 'text', key: 'result'}], authorize: async inputs => ({ method: 'auto', callback: async () => inputs.result }) }] } });`);
  const entry = join(directory, 'host.mjs');
  await writeFile(entry, `globalThis.fetch = async () => { throw new Error('Network forbidden'); }; await import(${JSON.stringify(pathToFileURL(join(runtime, 'vendor/magpie/host.js')).href)});`);
  const child = spawn(process.execPath, [entry], { cwd: directory, env: { ...process.env, HOME: directory, USERPROFILE: directory }, stdio: ['pipe', 'pipe', 'pipe'] });
  const pending = new Map();
  const lines = createInterface({ input: child.stdout });
  let next = 0, errors = '';
  child.stderr.on('data', chunk => { errors += chunk; });
  lines.on('line', line => {
    const message = JSON.parse(line), finish = pending.get(message.id);
    if (!finish) return;
    pending.delete(message.id);
    clearTimeout(finish.timeout);
    if (message.error) finish.reject(new Error(message.error.message)); else finish.resolve(message.result);
  });
  const exited = new Promise(resolve => child.once('exit', resolve));
  const rpc = (method, params) => new Promise((resolve, reject) => {
    const id = ++next;
    const timeout = setTimeout(() => { pending.delete(id); reject(new Error(`Native host ${method} timed out`)); }, 4000);
    pending.set(id, { resolve, reject, timeout });
    child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
  });
  const authPath = join(directory, 'plugin-auth.json');
  try {
    const initialized = await rpc('init', { directory, authPath, plugins: ['loomy', 'zcode'].map(provider => ({ spec: `synthetic-${provider}`, target: fixture, options: { provider } })) });
    expect(initialized.plugins.every(plugin => !plugin.error)).toBe(true);
    const signIn = async (provider, result) => {
      const start = await rpc('authorize', { provider, method: 0, inputs: { result } });
      return rpc('callback', { session: start.session });
    };
    await run({ rpc, signIn, saved: async () => JSON.parse(await readFile(authPath, 'utf8')) });
  } finally {
    child.stdin.end();
    const kill = setTimeout(() => child.kill(), 1500);
    await exited;
    clearTimeout(kill);
    lines.close();
    for (const p of pending.values()) clearTimeout(p.timeout);
  }
  expect(errors).toBe('');
}

test('native host preserves migrated Loomy slots and keeps same-mask official accounts separate', async () => {
  const first = await loomySignIn('13800001234', 'official-a');
  const second = await loomySignIn('13899991234', 'official-b');
  await nativeHost(async ({ rpc, signIn, saved }) => {
    const key = 'loomy#lp' + createHash('sha256').update('cn\0official-a').digest('hex').slice(0, 32);
    await rpc('import', { provider: 'loomy', key, auth: { type: 'oauth', accountId: 'official-a', uid: 'official-a', userId: 'official-a', access: 'old', refresh: '', expires: 0 } });
    expect(await signIn('loomy', first)).toMatchObject({ ok: true, account: key });
    const other = await signIn('loomy', second);
    expect(other.account).not.toBe(key);
    expect(Object.keys(await saved())).toHaveLength(2);
    expect((await saved())[key].access).toBe('fake-session-13800001234');
  });
});

test('native host reuses canonical migrated ZCode slot and isolates equal UID/email in the other region', async () => {
  const bigmodel = await zcodeSignIn('bigmodel');
  const zai = await zcodeSignIn('zai');
  await nativeHost(async ({ rpc, signIn, saved }) => {
    const key = 'zcode#lp' + createHash('sha256').update('bigmodel\0shared-uid').digest('hex').slice(0, 32);
    const untouched = { type: 'oauth', access: 'unrelated-secret', refresh: '', expires: 0, accountId: 'untouched', uid: 'other', metadata: { nested: ['preserve', 7] } };
    await rpc('import', { provider: 'loomy', key: 'loomy#unrelated', auth: untouched });
    await rpc('import', { provider: 'zcode', key, auth: { type: 'oauth', accountId: 'bigmodel:shared-uid', uid: 'shared-uid', access: 'old', refresh: JSON.stringify({ site: 'bigmodel', jwt: 'old' }), expires: 0 } });
    expect(await signIn('zcode', bigmodel)).toMatchObject({ ok: true, account: key });
    const other = await signIn('zcode', zai);
    expect(other.account).not.toBe(key);
    expect(await signIn('zcode', { ...bigmodel, name: 'renamed@example.invalid', access: 'renewed' })).toMatchObject({ ok: true, account: key });
    const all = await saved();
    expect(Object.keys(all)).toHaveLength(3);
    expect(all[key]).toMatchObject({ accountId: 'bigmodel:shared-uid', uid: 'shared-uid', access: 'renewed' });
    expect(all[other.account]).toMatchObject({ accountId: 'zai:shared-uid', uid: 'shared-uid', access: jwt });
    expect(all['loomy#unrelated']).toEqual(untouched);
  });
}, 10000);
