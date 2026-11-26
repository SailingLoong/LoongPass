import { afterEach, expect, test } from 'bun:test';
import { TraeCNAuthPlugin } from '../runtime/vendor/plugins/trae/opencode.mjs';

const enterprise = 'https://console.enterprise.trae.cn';
const personal = 'https://trae-api-cn.mchost.guru';
// an enterprise custom model's own endpoint, as an enterprise list names it
const ownEndpoint = 'https://gateway.example.test/erp/v1/chat/completions';
const ownModel = {
  config_name: 'AI/seat-model', config_source: 2, is_custom_model: true, status: true,
  display_config: { display_name: 'seat-model', is_custom_model: true },
  model_detail_list: [{ model_name: 'seat-model', provider: 'custom_openai_compatible', max_tokens: 4096,
    custom_config: { base_url: ownEndpoint, ak: 'seat-ak', auth_type: 0, status: true } }],
};
const auth = { type: 'oauth', access: 'fixture', uid: 'test-seat', expires: Date.UTC(2100, 0, 1) };
const seat = { ...auth, access: 'seat-access-token', host: enterprise, api: enterprise };
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

// an OpenAI chat completion stream, as an enterprise endpoint answers
function completion(text) {
  const chunk = (delta, finish = null) => `data: ${JSON.stringify({ id: 'c1', object: 'chat.completion.chunk', choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
  return new Response(chunk({ role: 'assistant', content: '' }) + chunk({ content: text }) + chunk({}, 'stop') + 'data: [DONE]\n\n', { headers: { 'content-type': 'text/event-stream' } });
}

async function provider(enterpriseReply, { models, endpointReply } = {}) {
  const chats = [], catalogs = [], saves = [], endpoints = [], endpointHeaders = [];
  globalThis.fetch = async (input, init) => {
    const { origin, pathname } = new URL(input);
    if (String(input) === ownEndpoint) {
      endpoints.push(init.body);
      endpointHeaders.push(init.headers);
      return endpointReply();
    }
    if (pathname === '/api/ide/v1/batch_get_detail_param') {
      catalogs.push(origin);
      return Response.json({ function_configs: [
        { function: 'chat_v3', config_info_list: models ?? [{ config_name: 'glm-5' }] },
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
  async function chat(record, model = 'glm-5') {
    const loader = await hooks.auth.loader(async () => record);
    return loader.fetch(loader.baseURL + '/chat/completions', {
      method: 'POST',
      body: JSON.stringify({ model, messages: [{ role: 'user', content: 'hello' }] }),
    });
  }
  return { hooks, chat, chats, catalogs, saves, endpoints, endpointHeaders };
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

test('TRAE CN asks an enterprise model at its own endpoint, with its key and not the sign-in', async () => {
  const p = await provider(() => { throw new Error('Unexpected llm_utils_chat request'); }, { models: [ownModel], endpointReply: () => completion('own endpoint') });
  await p.hooks.provider.models({ models: {} }, { auth: seat });
  const response = await p.chat(seat, ownModel.config_name);
  expect(response.status).toBe(200);
  expect((await response.json()).choices[0].message.content).toBe('own endpoint');
  expect(p.endpoints.length).toBe(1);
  expect(p.endpointHeaders[0].Authorization).toBe('Bearer seat-ak');
  expect(JSON.stringify(p.endpointHeaders)).not.toContain('seat-access-token');
  expect(p.chats).toEqual([]);
  expect(p.catalogs).toEqual([enterprise]);
});

for (const [name, reply] of [
  ['an error', () => new Response('unavailable', { status: 500 })],
  ['a refusal', () => new Response('denied', { status: 403 })],
]) {
  test(`TRAE CN answers an enterprise model through the enterprise console after ${name} from its endpoint`, async () => {
    const p = await provider(accepted, { models: [ownModel], endpointReply: reply });
    await p.hooks.provider.models({ models: {} }, { auth: seat });
    for (let i = 0; i < 2; i++) {
      const response = await p.chat(seat, ownModel.config_name);
      expect(response.status).toBe(200);
      expect((await response.json()).choices[0].message.content).toBe('accepted');
    }
    expect(p.chats).toEqual([enterprise, enterprise]);
    expect(p.catalogs.every(origin => origin === enterprise)).toBe(true);
    expect(p.saves).toEqual([]);
    // a refused key is not asked again until the seat's list gives another
    expect(p.endpoints.length).toBe(name === 'a refusal' ? 1 : 2);
  });
}
