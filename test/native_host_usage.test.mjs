// Actual pinned native-host RPC with synthetic auth/usage and no network.
// LOONGPASS_HOST_USAGE_PATH selects a private patched host for patch replay.
import { afterAll, beforeAll, expect, test } from 'bun:test';
import { spawn } from 'node:child_process';
import { copyFile, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath, pathToFileURL } from 'node:url';

const source = process.env.LOONGPASS_HOST_USAGE_PATH ?? resolve(dirname(fileURLToPath(import.meta.url)), '../runtime/vendor/magpie/host.js');
let temporary, child, lines, exited, windows;
let next = 0, errors = '';
const pending = new Map();
const rpc = (method, params) => new Promise((resolve, reject) => {
  const id = ++next;
  const timeout = setTimeout(() => { pending.delete(id); reject(new Error(`Native ${method} timed out`)); }, 4000);
  pending.set(id, { resolve, reject, timeout });
  child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
});

beforeAll(async () => {
  temporary = await mkdtemp(join(tmpdir(), 'loongpass-native-host-usage-'));
  const host = join(temporary, 'host.js'), entry = join(temporary, 'entry.mjs');
  await copyFile(source, host);
  await writeFile(entry, `globalThis.fetch = async () => { throw new Error('Network forbidden'); }; await import(${JSON.stringify(pathToFileURL(host).href)});`);
  const fixture = join(temporary, 'usage.mjs');
  await writeFile(fixture, `
    export const Synthetic = async () => ({
      config: async cfg => { cfg.provider = { fixture: { name:'Synthetic', api:'https://fixture.invalid/v1', models:{} } }; },
      auth: { provider:'fixture', methods:[], usage: async () => ({
        windows: [
          ...[
            ['missing',undefined], ['null',null], ['negative',-0.125],
            ['string','12.5'], ['NaN',NaN], ['infinity',Infinity],
            ['negative infinity',-Infinity], ['boolean',false], ['object',{}],
          ].map(([name,value]) => ({name,amount:value,limit:value,runsOut:value,unit:'credits'})),
          {name:'zero',amount:0,limit:0,runsOut:0,unit:'credits'},
          {name:'credits',amount:10.0625,limit:100.125,runsOut:90.0625,unit:'credits',family:'Claude',pool:'shared'},
          {name:'money',amount:0.125,limit:1.0625,runsOut:0.9375,unit:'usd'},
          {name:'tokens',amount:500000,limit:2000000,runsOut:1500000,unit:'tokens'},
          {name:'partial',amount:null,limit:100.125,runsOut:0,unit:'credits'},
        ],
      }) },
    });
  `);
  child = spawn(process.execPath, [entry], { cwd: temporary, env: { ...process.env, HOME: temporary, USERPROFILE: temporary }, stdio: ['pipe', 'pipe', 'pipe'] });
  child.stderr.on('data', chunk => { errors += chunk; });
  lines = createInterface({ input: child.stdout });
  lines.on('line', line => {
    const message = JSON.parse(line), finish = pending.get(message.id);
    if (!finish) return;
    pending.delete(message.id);
    clearTimeout(finish.timeout);
    if (message.error) finish.reject(new Error(message.error.message)); else finish.resolve(message.result);
  });
  exited = new Promise(resolve => child.once('exit', resolve));
  const initialized = await rpc('init', { directory: temporary, authPath: join(temporary, 'plugin-auth.json'), plugins: [{ spec: 'synthetic-usage', target: fixture }] });
  expect(initialized.plugins[0].error).toBeUndefined();
  await rpc('import', { provider: 'fixture', key: 'fixture#synthetic', auth: { type: 'oauth', access: 'fake', refresh: '', expires: 0, uid: 'synthetic', accountId: 'synthetic' } });
  const usage = await rpc('usage', { provider: 'fixture', account: 'fixture#synthetic' });
  windows = new Map(usage.windows.map(w => [w.name, w]));
});

afterAll(async () => {
  if (child) {
    child.stdin.end();
    const kill = setTimeout(() => child.kill(), 1500);
    await exited;
    clearTimeout(kill);
    lines.close();
  }
  for (const p of pending.values()) clearTimeout(p.timeout);
  if (temporary) await rm(temporary, { recursive: true, force: true });
  expect(errors).toBe('');
});

test('missing and invalid native quantities stay null rather than becoming zero', () => {
  for (const name of ['missing', 'null', 'negative', 'string', 'NaN', 'infinity', 'negative infinity', 'boolean', 'object']) {
    const window = windows.get(name);
    for (const field of ['amount', 'limit', 'runsOut']) expect(window[field]).toBeNull();
    expect(window.unit).toBe('credits');
  }
});

test('explicit zero remains a known amount and unknown fields are independent', () => {
  expect(windows.get('zero')).toMatchObject({ amount: 0, limit: 0, runsOut: 0, unit: 'credits' });
  expect(windows.get('partial')).toMatchObject({ amount: null, limit: 100.125, runsOut: 0, unit: 'credits' });
});

test('native host preserves absolute fractional credits through JSON RPC', () => {
  const credits = windows.get('credits');
  expect(credits).toMatchObject({ amount: 10.0625, limit: 100.125, runsOut: 90.0625, unit: 'credits' });
  // 1602/16 credits granted - 161/16 used = 1441/16 = 90.0625 remaining.
  expect(credits.limit - credits.amount).toBe(90.0625);
});

test('native host preserves monetary and token units without conversion', () => {
  expect(windows.get('money')).toMatchObject({ amount: 0.125, limit: 1.0625, runsOut: 0.9375, unit: 'usd' });
  expect(windows.get('tokens')).toMatchObject({ amount: 500000, limit: 2000000, runsOut: 1500000, unit: 'tokens' });
});

test('native shared-window grouping survives the host RPC', () => {
  expect(windows.get('credits')).toMatchObject({ family: 'Claude', pool: 'shared' });
});
