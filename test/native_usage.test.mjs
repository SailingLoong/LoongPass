// Pinned Bun, synthetic replies only. LOONGPASS_USAGE_RUNTIME may select a
// private patched runtime; packages and host account data stay in temp dirs.
import { afterAll, afterEach, beforeAll, expect, test } from 'bun:test';
import { spawn } from 'node:child_process';
import { cp, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath, pathToFileURL } from 'node:url';

const rootRuntime = resolve(dirname(fileURLToPath(import.meta.url)), '../runtime');
const runtime = process.env.LOONGPASS_USAGE_RUNTIME ?? rootRuntime;
const realFetch = globalThis.fetch;
const noNetwork = async () => { throw new Error('Network forbidden in native usage tests'); };
const future = Date.UTC(2100, 0, 1);
const auth = { type: 'oauth', uid: 'synthetic', accountId: 'synthetic', access: 'fake', refresh: '', expires: 0 };
let temporary, packages, mini, qoder, LoomyAuthPlugin, TraeCNAuthPlugin;
beforeAll(async () => {
  globalThis.fetch = noNetwork;
  temporary = await mkdtemp(join(tmpdir(), 'loongpass-native-usage-'));
  packages = join(temporary, 'plugins');
  await mkdir(packages);
  for (const name of ['minimax', 'trae', 'loomy', 'qoder']) {
    await cp(join(runtime, 'vendor/plugins', name), join(packages, name), { recursive: true });
  }
  ({ _internal: mini } = await import(pathToFileURL(join(packages, 'minimax/index.mjs')).href));
  ({ _internal: qoder } = await import(pathToFileURL(join(packages, 'qoder/index.mjs')).href));
  ({ LoomyAuthPlugin } = await import(pathToFileURL(join(packages, 'loomy/index.mjs')).href));
  ({ TraeCNAuthPlugin } = await import(pathToFileURL(join(packages, 'trae/index.mjs')).href));
});
afterEach(() => { globalThis.fetch = noNetwork; });
afterAll(async () => {
  globalThis.fetch = realFetch;
  if (temporary) await rm(temporary, { recursive: true, force: true });
});

const batch = (granted, remaining, expiry = future) => ({
  credit_type: 2, granted_amount: granted, remaining_amount: remaining, expire_at_ms: expiry,
});
test('MiniMax retains fractional credit amounts independently of formatted text', () => {
  const window = mini.creditsWindow([batch('100.125', '90.0625')], 0);
  // Manual calculation: 1602/16 granted - 1441/16 left = 161/16 used.
  expect(window.amount).toBe(10.0625);
  expect(window.limit).toBe(100.125);
  expect(window.limit - window.amount).toBe(90.0625);
  expect(window.runsOut).toBe(90.0625);
  expect(window.unit).toBe('credits');
  expect(window.display).toBe('10.06 / 100.13');
  expect(window.runsOutAt).toBe('2100-01-01T00:00:00.000Z');
});

test('MiniMax sums every remaining batch at the same earliest expiry', () => {
  const window = mini.creditsWindow([
    batch('100.125', '90.0625'), batch('20.125', '10.125'),
    batch('40', '8.5', future + 86400000), batch('9', '9', 1),
  ], 2);
  // 1441/16 + 162/16 = 1603/16 = 100.1875 credits lost together.
  expect(window.runsOut).toBe(100.1875);
  expect(window.amount).toBe(51.5625);
  expect(window.limit).toBe(160.25);
  expect(window.limit - window.amount).toBe(108.6875);
  expect(window.runsOutAt).toBe('2100-01-01T00:00:00.000Z');
});

test('TRAE CN public usage retains exact credits, not two-decimal amounts', async () => {
  let calls = 0;
  globalThis.fetch = async (input, init) => {
    expect(new URL(String(input)).pathname).toBe('/trae/api/v2/pay/ide_user_ent_usage');
    expect(init.method).toBe('POST');
    calls++;
    return Response.json({ user_entitlement_pack_list: [{
      entitlement_base_info: { entitlement_id: 'fixture', quota: { credits_limit: 100.125 }, end_time: future / 1000 },
      usage: { credits_amount: 10.0625 },
    }] });
  };
  const hooks = await TraeCNAuthPlugin({});
  const usage = await hooks.auth.usage(async () => auth);
  expect(calls).toBe(1);
  expect(usage.windows[0]).toMatchObject({ amount: 10.0625, limit: 100.125, unit: 'credits' });
  expect(usage.windows[0].limit - usage.windows[0].amount).toBe(90.0625);
});

async function loomyUsage(data) {
  let calls = 0;
  globalThis.fetch = async (input, init) => {
    expect(new URL(String(input)).pathname).toBe('/api/v2/points/records');
    expect(init.method).toBe('GET');
    calls++;
    return Response.json({ code: '000000', data });
  };
  const hooks = await LoomyAuthPlugin();
  const result = await hooks.auth.usage(async () => auth);
  expect(calls).toBe(1);
  return result;
}

test('Loomy reports spent credits, percentage, and remaining balance in their own fields', async () => {
  const usage = await loomyUsage({ dailyLimitPoints: '50.125', dailyRemainingPoints: '37.59375', balance: '10.0625' });
  // 50.125 - 37.59375 = 12.53125 credits; 12.53125/50.125 = 25%.
  expect(usage.windows[0]).toMatchObject({ amount: 12.53125, limit: 50.125, used: 25, balance: 37.59375, unit: 'credits' });
  expect(usage.windows[1]).toMatchObject({ balance: 10.0625, unit: 'credits', display: '10.0625 credits' });
  expect(usage.windows[1].used).toBeUndefined();
  expect(usage.windows[1].limit).toBeUndefined();
});

test('Loomy balance-only wallets keep unknown totals and usage unknown', async () => {
  const usage = await loomyUsage({ dailyBalance: '123.0625', balance: 0 });
  expect(usage.windows).toHaveLength(2);
  expect(usage.windows[0]).toMatchObject({ balance: 123.0625, unit: 'credits', display: '123.0625 credits' });
  expect(usage.windows[1].balance).toBe(0);
  for (const window of usage.windows) {
    expect(window.used).toBeUndefined();
    expect(window.amount).toBeUndefined();
    expect(window.limit).toBeUndefined();
  }
  expect((await loomyUsage({})).error).toBeTruthy();
});

test('Loomy remaining-only daily reply does not require an unknown limit', async () => {
  const usage = await loomyUsage({ dailyRemainingPoints: '123.0625' });
  expect(usage.windows).toHaveLength(1);
  expect(usage.windows[0]).toMatchObject({ balance: 123.0625, unit: 'credits' });
  expect(usage.windows[0].amount).toBeUndefined();
  expect(usage.windows[0].limit).toBeUndefined();
  expect(usage.windows[0].used).toBeUndefined();
});

const qoderUsage = data => qoder.parseUsage({ displayMode: 'qoder', qoderUsage: data });
test('Qoder retains remaining-only packages and their own official expiry', () => {
  const usage = qoderUsage({
    expiresAt: '2099-01-01T00:00:00Z',
    userQuota: { total: 1000, used: 100 },
    addOnQuota: { total: 200, used: 25 },
    dedicatedResourcePackages: [{ name: 'Activity', remaining: 125.0625, expiresAt: '2100-01-01T08:00:00+08:00' }],
  });
  const packageWindow = usage.windows.find(w => w.name === 'Activity');
  expect(packageWindow).toMatchObject({ balance: 125.0625, unit: 'credits', runsOut: 125.0625, runsOutAt: '2100-01-01T00:00:00.000Z', aside: true });
  expect(packageWindow.amount).toBeUndefined();
  expect(packageWindow.limit).toBeUndefined();
  expect(packageWindow.used).toBeUndefined();
  expect(packageWindow.resetsAt).toBeUndefined();
  expect(usage.windows[0]).toMatchObject({ name: 'Total credits', amount: 125, limit: 1200, unit: 'credits' });
  expect(usage.windows[0].runsOutAt).toBeUndefined();
  expect(usage.windows.find(w => w.name === 'Add-on credits').resetsAt).toBeUndefined();
});

test('Qoder keeps fractional package remainder and units without summing overlapping pools', () => {
  const usage = qoderUsage({ dedicated_resource_packages: [
    { name: 'Derived', total: 100.125, used: 10.0625, expires_at: future / 1000 },
    { name: 'Official', total: 100, used: 5, remaining: 70.125, expiresAt: future },
    { name: 'Tokens', remaining: 500000, unit: 'tokens', expiresAt: future },
  ] });
  expect(usage.windows).toHaveLength(3);
  expect(usage.windows[0]).toMatchObject({ amount: 10.0625, limit: 100.125, balance: 90.0625, runsOut: 90.0625, unit: 'credits', runsOutAt: '2100-01-01T00:00:00.000Z' });
  expect(usage.windows[0].display).toBe('10.0625 / 100.125 credits');
  expect(usage.windows[1]).toMatchObject({ balance: 70.125, runsOut: 70.125 });
  expect(usage.windows[2]).toMatchObject({ balance: 500000, runsOut: 500000, unit: 'tokens' });
  expect(usage.windows.some(w => w.name === 'Total credits')).toBe(false);
});

test('Qoder unknown or sentinel expiry is not replaced by a plan renewal', () => {
  const usage = qoderUsage({ expiresAt: '2099-01-01T00:00:00Z', dedicatedResourcePackages: [
    { name: 'Missing', remaining: 20.125 },
    { name: 'Sentinel', remaining: 30.0625, expiresAt: '9999-01-01T00:00:00Z' },
    { name: 'Numeric sentinel', remaining: 15.125, expiresAt: 253402214400000 },
    { name: 'Invalid', remaining: 40, expires_at: 'unknown' },
  ] });
  expect(usage.windows.map(w => w.balance)).toEqual([20.125, 30.0625, 15.125, 40]);
  for (const window of usage.windows) {
    expect(window.runsOutAt).toBeUndefined();
    expect(window.runsOut).toBeUndefined();
    expect(window.resetsAt).toBeUndefined();
  }
});

test('Qoder excludes expired, unavailable, and grant-only package records', () => {
  const usage = qoderUsage({ dedicatedResourcePackages: [
    { name: 'Expired', remaining: 999, expiresAt: '2000-01-01T00:00:00Z' },
    { name: 'Unavailable', remaining: 200, available: false, expiresAt: future },
    { name: 'Grant only', total: 500, expiresAt: future },
    { name: 'Known zero', remaining: 0, expiresAt: future },
  ] });
  expect(usage.windows).toHaveLength(1);
  expect(usage.windows[0]).toMatchObject({ name: 'Known zero', balance: 0, unit: 'credits' });
});

test('native host roundtrip preserves Loomy precise balance and percentage', async () => {
  const directory = await mkdtemp(join(temporary, 'host-'));
  const entry = join(directory, 'host.mjs');
  await writeFile(entry, `
    globalThis.fetch = async (input, init) => {
      if (new URL(String(input)).pathname !== '/api/v2/points/records' || init.method !== 'GET') throw new Error('Network forbidden');
      return Response.json({code:'000000', data:{dailyLimitPoints:50.125,dailyRemainingPoints:37.59375,balance:10.0625}});
    };
    await import(${JSON.stringify(pathToFileURL(join(rootRuntime, 'vendor/magpie/host.js')).href)});
  `);
  const child = spawn(process.execPath, [entry], { cwd: directory, env: { ...process.env, HOME: directory, USERPROFILE: directory }, stdio: ['pipe', 'pipe', 'pipe'] });
  const pending = new Map();
  let next = 0, errors = '';
  child.stderr.on('data', chunk => { errors += chunk; });
  const lines = createInterface({ input: child.stdout });
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
    const timeout = setTimeout(() => { pending.delete(id); reject(new Error(`Native ${method} timed out`)); }, 4000);
    pending.set(id, { resolve, reject, timeout });
    child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
  });
  try {
    const initialized = await rpc('init', { directory, authPath: join(directory, 'plugin-auth.json'), plugins: [{ spec: 'synthetic-loomy', target: join(packages, 'loomy/index.mjs') }] });
    expect(initialized.plugins[0].error).toBeUndefined();
    await rpc('import', { provider: 'loomy', key: 'loomy#synthetic', auth });
    const usage = await rpc('usage', { provider: 'loomy', account: 'loomy#synthetic' });
    expect(usage.windows[0]).toMatchObject({ amount: 12.53125, limit: 50.125, used: 25, balance: 37.59375, unit: 'credits' });
    expect(usage.windows[1]).toMatchObject({ balance: 10.0625, unit: 'credits', used: null });
  } finally {
    child.stdin.end();
    const kill = setTimeout(() => child.kill(), 1500);
    await exited;
    clearTimeout(kill);
    lines.close();
    for (const p of pending.values()) clearTimeout(p.timeout);
  }
  expect(errors).toBe('');
});
