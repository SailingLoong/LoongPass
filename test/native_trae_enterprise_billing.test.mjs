import { afterEach, expect, test } from 'bun:test';
import { TraeCNAuthPlugin } from '../runtime/vendor/plugins/trae/opencode.mjs';

const enterprise = 'https://console.enterprise.trae.cn';
const personal = 'https://trae-api-cn.mchost.guru';
const auth = { type: 'oauth', access: 'fixture', uid: 'test-seat', expires: Date.UTC(2100, 0, 1) };
const refusal = { code: 4245, message: 'seat permission denied' };
const realFetch = globalThis.fetch;
afterEach(() => { globalThis.fetch = realFetch; });

function events(rows) {
  const body = rows.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`).join('');
  return new Response(body, { headers: { 'content-type': 'text/event-stream' } });
}

function accepted() {
  return events([['output', { response: 'accepted' }], ['done', {}]]);
}

async function provider(enterpriseReply) {
  const chats = [], catalogs = [], saves = [];
  globalThis.fetch = async (input) => {
    const { origin, pathname } = new URL(input);
    if (pathname === '/api/ide/v1/batch_get_detail_param') {
      catalogs.push(origin);
      return Response.json({ function_configs: [
        { function: 'chat_v3', config_info_list: [{ config_name: 'glm-5' }] },
      ] });
    }
    if (pathname !== '/api/agent/v3/llm_utils_chat') throw new Error(`Unexpected request ${pathname}`);
    chats.push(origin);
    if (origin === enterprise) return enterpriseReply();
    if (origin === personal) return accepted();
    throw new Error(`Unexpected chat origin ${origin}`);
  };
  const client = { auth: { set: async ({ body }) => { saves.push(body); } } };
  const hooks = await TraeCNAuthPlugin({ client });
  async function chat(record) {
    const loader = await hooks.auth.loader(async () => record);
    return loader.fetch(loader.baseURL + '/chat/completions', {
      method: 'POST',
      body: JSON.stringify({ model: 'glm-5', messages: [{ role: 'user', content: 'hello' }] }),
    });
  }
  return { hooks, chat, chats, catalogs, saves };
}

for (const [name, reject, status] of [
  ['HTTP error', () => Response.json(refusal, { status: 400 }), 400],
  ['business error', () => Response.json(refusal), 502],
  ['stream error', () => events([['error', refusal]]), 502],
]) {
  test(`TRAE CN keeps enterprise billing after a 4245 ${name}`, async () => {
    const p = await provider(reject);
    const record = { ...auth, host: enterprise, api: enterprise };
    for (let i = 0; i < 2; i++) {
      const response = await p.chat(record);
      expect(response.status).toBe(status);
      expect(await response.text()).toContain('4245');
    }
    expect(p.chats).toEqual([enterprise, enterprise]);
    expect(p.catalogs.every(origin => origin === enterprise)).toBe(true);
    expect(p.saves).toEqual([]);
  });
}

for (const [name, fields] of [
  ['stored console', { host: enterprise, api: enterprise }],
  ['older host-only record', { host: enterprise }],
]) {
  test(`TRAE CN reads and uses the ${name} despite a legacy fallback marker`, async () => {
    const p = await provider(accepted);
    const record = { ...auth, ...fields, consoleChat: false };
    await p.hooks.provider.models({ models: {} }, { auth: record });
    expect(p.catalogs).toEqual([enterprise]);
    const response = await p.chat(record);
    expect(response.status).toBe(200);
    expect((await response.json()).choices[0].message.content).toBe('accepted');
    expect(p.chats).toEqual([enterprise]);
    expect(p.saves).toEqual([]);
  });
}

test('TRAE CN serves a personal sign-in through its personal gateway', async () => {
  const p = await provider(() => { throw new Error('Unexpected enterprise request'); });
  const response = await p.chat(auth);
  expect(response.status).toBe(200);
  expect((await response.json()).choices[0].message.content).toBe('accepted');
  expect(p.chats).toEqual([personal]);
});
