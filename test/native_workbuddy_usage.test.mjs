// Regression from the native routing trace and free-window contracts.
import { expect, test } from 'bun:test';
import { cp, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

test('WorkBuddy preserves a routed reset when the saved account differs only in case', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'loongpass-workbuddy-usage-'));
  try {
    const runtime = process.env.LOONGPASS_USAGE_RUNTIME ?? resolve('runtime');
    await cp(join(runtime, 'vendor/plugins/workbuddy'), join(directory, 'workbuddy'), { recursive: true });
    const { _internal: { routingRefusalRows, freeWindowOf } } = await import(pathToFileURL(join(directory, 'workbuddy/index.mjs')).href);
    const account = 'mixed-CASE@example.COM';
    const now = Date.parse('2026-11-02T12:30:00+08:00');
    const trace = JSON.stringify({
      time: '2026-11-02T12:00:00+08:00',
      order: [{ id:'wb-me', provider:'workbuddy-ai', who:'Mixed-Case@Example.com' }],
      tries: [{ id:'wb-me', provider:'workbuddy-ai', model:'deepseek-v4.1-flash', status:429,
        start:'2026-11-02T12:00:01+08:00', error:'reset at 2026-11-02 19:17:02 UTC+8',
        rest:{ by:'resets', key:'workbuddy-ai@mixed-case@example.com/deepseek-v4.1-flash', until:'2026-11-02T19:17:02+08:00' } }],
    });
    const refused = routingRefusalRows('', false, now, account, undefined, trace);
    expect(refused).toHaveLength(1);
    const answered = { provider:'workbuddy-ai', providerAccount:account, model:'deepseek-v4.1-flash',
      t:'2026-11-02T02:00:00+08:00', status:200, in:1, cache_read:0, out:0 };
    const window = freeWindowOf([answered, ...refused], account, now);
    expect(window).toMatchObject({ refused:true, used:100, amount:100000000, resetsAt:'2026-11-02T11:17:02.000Z' });
    expect(window.aside).toBeUndefined();
    // A sibling account cannot inherit that reset.
    expect(freeWindowOf(refused, 'another@example.invalid', now)).toBeNull();
  } finally {
    await rm(directory, { recursive:true, force:true });
  }
});
