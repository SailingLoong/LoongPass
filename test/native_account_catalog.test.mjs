// Native account admission with synthetic credentials only; no network.
import { afterEach, beforeEach, expect, test } from 'bun:test';
import { spawn } from 'node:child_process';
import { copyFile, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath, pathToFileURL } from 'node:url';

const source = process.env.LOONGPASS_HOST_ACCOUNT_CATALOG_PATH ?? resolve(dirname(fileURLToPath(import.meta.url)), '../runtime/vendor/magpie/host.js');
let directory, child, lines, exited, errors, next;
const pending = new Map();
const rpc = (method, params) => new Promise((resolve, reject) => {
  const id = ++next;
  const timer = setTimeout(() => { pending.delete(id); reject(new Error(`Native ${method} timed out`)); }, 4000);
  pending.set(id, { resolve, reject, timer, events: [] });
  child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
});
async function start() {
  child = spawn(process.execPath, [join(directory, 'entry.mjs')], { cwd: directory, env: { ...process.env, HOME: directory, USERPROFILE: directory }, stdio: ['pipe', 'pipe', 'pipe'] });
  errors = ''; next = 0;
  child.stderr.on('data', chunk => { errors += chunk; });
  lines = createInterface({ input: child.stdout });
  lines.on('line', line => {
    const message = JSON.parse(line), call = pending.get(message.id);
    if (!call) return;
    if (message.event) { call.events.push(message); return; }
    pending.delete(message.id); clearTimeout(call.timer);
    if (message.error) call.reject(new Error(message.error.message));
    else call.resolve({ result: message.result, events: call.events });
  });
  exited = new Promise(resolve => child.once('exit', resolve));
  const initialized = await rpc('init', { directory, authPath: join(directory, 'plugin-auth.json'), plugins: [{ spec: 'catalog-fixture', target: join(directory, 'fixture.mjs') }] });
  expect(initialized.result.plugins[0].error).toBeUndefined();
}
async function stop() {
  if (!child) return;
  child.stdin.end(); const kill = setTimeout(() => child.kill(), 1500);
  await exited; clearTimeout(kill); lines.close(); child = null;
  expect(errors).toBe('');
}
const calls = async () => JSON.parse(await readFile(join(directory, 'calls.json'), 'utf8').catch(() => '[]'));
const auth = uid => ({ type: 'oauth', uid, accountId: '138****1234', access: `fake-${uid}`, refresh: `fake-refresh-${uid}`, expires: 1 });
async function seed() {
  for (const [key, uid] of [['fixture', 'blocked-uid'], ['fixture#good', 'healthy-uid']])
    await rpc('import', { provider: 'fixture', key, auth: auth(uid) });
}
beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), 'loongpass-account-catalog-'));
  await copyFile(source, join(directory, 'host.js'));
  await writeFile(join(directory, 'entry.mjs'), `globalThis.fetch = async () => { throw new Error('Network forbidden'); }; await import(${JSON.stringify(pathToFileURL(join(directory, 'host.js')).href)});`);
  await writeFile(join(directory, 'fixture.mjs'), `
    import {readFileSync,writeFileSync,existsSync} from 'node:fs';
    const note = (hook,uid) => {const rows=existsSync('calls.json')?JSON.parse(readFileSync('calls.json','utf8')):[];rows.push({hook,uid});writeFileSync('calls.json',JSON.stringify(rows));};
    export const Fixture = async () => ({
      config: async cfg => { cfg.provider = { fixture: {name:'Fixture',api:'https://fixture.invalid/v1',models:{static:{name:'Static'}}} }; },
      auth: { provider:'fixture', methods:[], refreshLead:0,
        refresh:async a => {note('refresh',a.uid);return {...a,access:'renewed-'+a.uid,expires:Date.now()+3600000};},
        loader:async getAuth => {const a=await getAuth();note('loader',a.uid);return {baseURL:'https://fixture.invalid/v1',apiKey:a.access,
          fetch:async () => {const a=await getAuth();note('fetch',a.uid);return Response.json({uid:a.uid,access:a.access});}};},
      },
      provider:{id:'fixture',models:async (given,{auth}) => {note('models',auth?.uid ?? 'none');return {[auth.uid]:{name:auth.uid,api:{id:'native-model',url:'https://fixture.invalid/v1',npm:'@ai-sdk/openai-compatible'}}};}},
    });
  `);
  await start();
});
afterEach(async () => {
  await stop();
  for (const call of pending.values()) clearTimeout(call.timer);
  pending.clear();
  if (directory) await rm(directory, { recursive: true, force: true });
});

test('blocked default slot stays untouched while healthy sibling lists and infers after restart', async () => {
  await seed(); await stop(); await start();
  const rows = (await rpc('providers', { offAccounts: ['fixture'] })).result;
  expect(rows[0].accounts.map(a => a.key)).toEqual(['fixture#good']);
  expect(rows[0].models.map(m => m.id)).toEqual(['healthy-uid']);
  expect((await rpc('load', {provider:'fixture',account:'fixture#good'})).result.apiKey).toBe('renewed-healthy-uid');
  const fetched = await rpc('fetch', {provider:'fixture',account:'fixture#good',model:'healthy-uid',npm:'@ai-sdk/openai-compatible',url:'https://fixture.invalid/v1/chat/completions',method:'POST',body:Buffer.from('{"model":"native-model"}').toString('base64')});
  expect(fetched.events.find(e => e.event === 'head').status).toBe(200);
  const body = JSON.parse(Buffer.concat(fetched.events.filter(e => e.event === 'chunk').map(e => Buffer.from(e.data,'base64'))).toString());
  expect(body).toEqual({uid:'healthy-uid',access:'renewed-healthy-uid'});
  expect((await calls()).map(c => c.uid)).not.toContain('blocked-uid');
  const saved = JSON.parse(await readFile(join(directory,'plugin-auth.json'),'utf8'));
  expect(saved.fixture).toEqual(auth('blocked-uid'));
});

test('all excluded slots yield static metadata without model or renewal hooks', async () => {
  await seed();
  const row = (await rpc('providers', {offAccounts:['fixture','fixture#good']})).result[0];
  expect(row.accounts).toEqual([]);
  expect(row.signedIn).toBe(false);
  expect(row.models.map(m => m.id)).toEqual(['static']);
  expect(await calls()).toEqual([]);
});

test('explicit account filtering with no connected slots invokes no hooks', async () => {
  const row = (await rpc('providers', {offAccounts:[]})).result[0];
  expect(row.accounts).toEqual([]);
  expect(row.models.map(m => m.id)).toEqual(['static']);
  expect(await calls()).toEqual([]);
});

test('omitting offAccounts preserves the native multi-account contract', async () => {
  await seed();
  const row = (await rpc('providers', {})).result[0];
  expect(row.accounts.map(a => a.key)).toEqual(['fixture','fixture#good']);
  expect(row.models.map(m => m.id).sort()).toEqual(['blocked-uid','healthy-uid']);
  expect((await calls()).filter(c => c.hook === 'models').map(c => c.uid).sort()).toEqual(['blocked-uid','healthy-uid']);
});
