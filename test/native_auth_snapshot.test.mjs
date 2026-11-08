// Synthetic native storage only; snapshot must not invoke supplier hooks.
import { expect, test } from 'bun:test';
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';

test('native auth snapshot uses the native known/backup boundary without hooks', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'loongpass-auth-snapshot-'));
  const authPath = join(directory, 'plugin-auth.json');
  const fixture = join(directory, 'fixture.mjs');
  await writeFile(fixture, `import {appendFileSync} from 'node:fs';
  const hook = async () => {appendFileSync('hooks-called','called'); throw new Error('Snapshot invoked a hook');};
  export const Fixture = async () => ({ auth: {
    provider:'fixture', methods:[], refresh:hook, loader:hook
  }, provider:{id:'fixture',models:hook} });`);
  const child = spawn(process.execPath, [process.env.LOONGPASS_AUTH_SNAPSHOT_HOST ?? resolve('runtime/vendor/magpie/host.js')], {
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
    await rpc('init', { authPath, directory, plugins: [{ spec:'snapshot-fixture', target:fixture }] });
    expect(await rpc('authSnapshot')).toEqual({}); // Missing primary is native known-empty.
    const saved = { 'fixture#a': { type:'oauth', uid:'official', accountId:'official', access:'synthetic', refresh:'synthetic-refresh', expires:1, metadata:{nested:'original'} } };
    await writeFile(authPath, '{truncated');
    await writeFile(authPath + '.bak', JSON.stringify(saved));
    const snapshot = await rpc('authSnapshot');
    expect(snapshot).toEqual(saved);
    snapshot['fixture#a'].metadata.nested = 'changed';
    expect(await rpc('authSnapshot')).toEqual(saved);
    expect(await readFile(authPath, 'utf8')).toBe('{truncated');
    await writeFile(authPath + '.bak', '{also-truncated');
    await expect(rpc('authSnapshot')).rejects.toThrow();
    expect(existsSync(join(directory, 'hooks-called'))).toBe(false);
  } finally {
    child.stdin.end();
    const timer = setTimeout(() => child.kill(), 1500);
    await exited; clearTimeout(timer); lines.close();
    for (const p of pending.values()) clearTimeout(p.timer);
    await rm(directory, { recursive:true, force:true });
  }
});
