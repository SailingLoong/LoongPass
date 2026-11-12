// The adopted native host owns auth persistence. All accounts and hooks here
// are synthetic and isolated; no vendor or installed client's data is read.
import { expect, test } from 'bun:test';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';

test('native auth keeps access-only OAuth, refuses empty success and excludes typed secrets from API metadata', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'loongpass-host-auth-'));
  const authPath = join(directory, 'plugin-auth.json');
  const fixture = join(directory, 'fixture.mjs');
  await writeFile(fixture, `export const Fixture = async () => ({ auth: {
    provider:'fixture', methods:[
      {type:'oauth',label:'access only',authorize:async()=>({method:'auto',callback:async()=>({type:'success',access:'synthetic-access',uid:'official-access'})})},
      {type:'oauth',label:'empty',authorize:async()=>({method:'auto',callback:async()=>({type:'success'})})},
      {type:'api',label:'typed key',prompts:[
        {type:'text',key:'secret',message:'Key'},
        {type:'select',key:'site',message:'Site',options:[{label:'CN',value:'cn'}]}
      ],authorize:async inputs=>({type:'success',key:inputs.secret,metadata:{official:'account-a'}})}
    ]
  }});`);
  const child = spawn(process.execPath, [resolve('runtime/vendor/magpie/host.js')], {
    cwd: directory, env: { ...process.env, HOME: directory, USERPROFILE: directory }, stdio: ['pipe', 'pipe', 'ignore'],
  });
  const exited = new Promise(resolve => child.once('exit', resolve));
  const pending = new Map(); let next = 0;
  const lines = createInterface({ input: child.stdout });
  lines.on('line', line => {
    const message = JSON.parse(line), p = pending.get(message.id);
    if (!p) return;
    pending.delete(message.id); clearTimeout(p.timer);
    if (message.error) p.reject(new Error(message.error.message)); else p.resolve(message.result);
  });
  const rpc = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++next;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('RPC timeout')); }, 4000);
    pending.set(id, { resolve, reject, timer });
    child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
  });
  try {
    await rpc('init', { authPath, directory, plugins: [{ spec:'auth-fixture', target:fixture }] });
    const start = await rpc('authorize', {provider:'fixture', method:0});
    expect((await rpc('callback', {session:start.session})).ok).toBe(true);
    expect(Object.values(await rpc('authSnapshot'))).toContainEqual(expect.objectContaining({access:'synthetic-access', refresh:''}));
    let saved = JSON.parse(await readFile(authPath, 'utf8'));
    expect(Object.values(saved)).toContainEqual(expect.objectContaining({access:'synthetic-access', refresh:''}));

    const empty = await rpc('authorize', {provider:'fixture', method:1});
    expect((await rpc('callback', {session:empty.session})).ok).toBe(false);
    expect(JSON.parse(await readFile(authPath, 'utf8'))).toEqual(saved);

    const result = await rpc('apiKey', {provider:'fixture', method:2, inputs:{secret:'synthetic-key',site:'cn'}, accountId:'cn:official'});
    expect(result.ok).toBe(true);
    saved = JSON.parse(await readFile(authPath, 'utf8'));
    expect(saved[result.account]).toMatchObject({type:'api',key:'synthetic-key',accountId:'cn:official',metadata:{site:'cn',official:'account-a'}});
    expect(saved[result.account].metadata.secret).toBeUndefined();
    const catalog = await rpc('providers');
    expect(catalog[0].methods[2]).toMatchObject({keyAsked:true});
  } finally {
    child.stdin.end();
    const timer = setTimeout(() => child.kill(), 1500);
    await exited; clearTimeout(timer); lines.close();
    for (const p of pending.values()) clearTimeout(p.timer);
    await rm(directory, { recursive:true, force:true });
  }
});
