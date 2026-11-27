// Run in a child with its own home. Only synthetic OAuth traffic is accepted.
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const { ZCodeAuthPlugin } = await import(pathToFileURL(process.argv[2]).href);
const device = '01234567-89ab-4cde-abcd-0123456789ab';
const jwt = 'e30.' + Buffer.from(JSON.stringify({ exp: 4102444800 })).toString('base64url') + '.fake';
const desktop = join(homedir(), '.zcode', 'v2');
await mkdir(desktop, { recursive: true });
await writeFile(join(desktop, 'telemetry-state.json'), JSON.stringify({ deviceMid: device }));

async function zcodeSignIn(site, { user = { user_id: 'shared-uid', email: 'same@example.invalid' }, paid = false, team = false } = {}) {
  const api = site === 'bigmodel' ? 'bigmodel.cn' : 'api.z.ai';
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(String(input));
    const answer = (data) => Response.json({ code: 0, data });
    if (url.hostname === 'zcode.z.ai') {
      if (url.pathname === '/api/v1/oauth/cli/init') {
        assert.equal(JSON.parse(init.body).provider, site);
        assert.equal(new Headers(init.headers).get('x-device-mid'), device);
        return answer({ flow_id: 'synthetic', authorize_url: `https://${site === 'bigmodel' ? 'bigmodel.cn' : 'z.ai'}/login`, poll_interval_sec: 1 });
      }
      if (url.pathname === '/api/v1/oauth/cli/poll/synthetic') return answer({ status: 'ready', user, token: jwt, [site]: { access_token: 'fake-vendor-token' } });
      if (url.pathname === '/api/v1/zcode-plan/billing/balance') return answer({ plans: [{ plan_id: 'gift', status: 'active', name: 'Start Plan' }], balances: [] });
    }
    if (url.pathname === '/api/biz/subscription/list' && url.hostname === (site === 'bigmodel' ? 'open.bigmodel.cn' : api)) return answer([{ status: 'VALID', productName: 'GLM Coding Pro' }]);
    if (url.hostname !== api) throw new Error('Unexpected network request in test');
    if (url.pathname === '/api/auth/z/login') return answer({ access_token: 'fake-biz-token' });
    if (url.pathname === '/api/biz/customer/getCustomerInfo') return answer({ organizations: paid || team ? [{ organizationId: 'org', projects: [{ projectId: 'project', projectType: team ? 2 : 1 }] }] : [] });
    if (url.pathname.endsWith('/api_keys')) return answer([{ apiKey: 'fake-key', name: team ? 'zcode-team-api-key' : 'zcode-api-key', keyType: team ? 2 : 1 }]);
    if (url.pathname.endsWith('/api_keys/copy/fake-key')) return answer({ secretKey: 'fake-secret' });
    if (url.pathname === '/api/biz/team/subscribe/product/querySubscribeDetail') return answer({ status: 'EFFECTIVE', memberGrantStatus: 'VALID', productName: 'GLM Coding Team' });
    throw new Error('Unexpected network request in test');
  };
  const hooks = await ZCodeAuthPlugin();
  const method = hooks.auth.methods[team ? 2 : site === 'bigmodel' ? 1 : 0];
  return (await method.authorize({ site })).callback();
}

const { site, options } = JSON.parse(await Bun.stdin.text());
process.stdout.write(JSON.stringify(await zcodeSignIn(site, options)));
