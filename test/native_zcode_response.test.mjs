// Native grant routing and reply transforms, based on the upstream dual-account
// and ToolSearch contracts. Network and account data are entirely synthetic.
import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from 'bun:test';
import { cp, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const runtime = process.env.LOONGPASS_RESPONSE_RUNTIME ?? resolve('runtime');
const realFetch = globalThis.fetch;
const now = Math.trunc(Date.now() / 1000);
const jwt = 'e30.' + Buffer.from(JSON.stringify({exp:now+3600})).toString('base64url') + '.fake';
const auth = { type:'oauth', uid:'official-a', access:'dual.secret', expires:0,
  refresh:JSON.stringify({site:'zai',base:'https://api.z.ai/api/anthropic',key:'dual.secret',jwt,device:'11111111-2222-4333-8444-555555555555',plan:'GLM Coding Pro'}) };
const balance = {
  server_time:now,
  plans:[{plan_id:'zai-start-plan',user_plan_id:'up1',name:'Start Plan',status:'active',ends_at:now+604800,entitlements:[{entitlement_id:'e1',period:'daily'}]}],
  balances:[{plan_id:'zai-start-plan',user_plan_id:'up1',entitlement_id:'e1',show_name:'Trust Build',capabilities:['model:glm-5.3-flash'],total_units:1000,used_units:250,remaining_units:750,expires_at:now+3600}],
};
let directory, plugin, native;
const sent = [];
let stream, fallback, hold;
beforeAll(async () => {
  directory = await mkdtemp(join(tmpdir(), 'loongpass-zcode-response-'));
  await cp(join(runtime, 'vendor/plugins/zcode'), join(directory, 'zcode'), {recursive:true});
  ({ZCodeAuthPlugin:plugin,_internal:native} = await import(pathToFileURL(join(directory,'zcode/index.mjs')).href));
});
beforeEach(() => {
  for (const name of ['routes','blocked','sidelined']) native[name].clear();
  native.edge.until = 0;
  native.busyHold.until = 0; native.busyHold.hits.length = 0;
  native.startGate.lanes.clear(); native.startGate.narrow?.clear();
  sent.length = 0; hold = false;
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    const path = url.pathname;
    if (path === '/api/biz/subscription/list') return Response.json({code:0,data:[{productName:'GLM Coding Pro',status:'VALID'}]});
    if (path === '/api/v1/zcode-plan/billing/balance') return Response.json({code:0,data:balance});
    if (!path.endsWith('/messages')) throw new Error('Unexpected synthetic endpoint: '+path);
    sent.push({path,body:JSON.parse(init.body)});
    if (fallback && path === '/api/v1/zcode-plan/anthropic/v1/messages') return new Response('unavailable',{status:500});
    if (hold) return new Response(new ReadableStream({start(c){c.enqueue(new TextEncoder().encode('event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":\"glm-5.3-flash\"}}\n\n'));}}),{headers:{'content-type':'text/event-stream'}});
    const tool = {type:'tool_use',id:'toolu_probe',name:'ToolSearchTool',input:{query:'select:Read'}};
    if (!stream) return Response.json({type:'message',model:'glm-5.3-flash',content:[tool],stop_reason:'tool_use'});
    return new Response([
      {type:'message_start',message:{type:'message',model:'glm-5.3-flash',content:[]}},
      {type:'content_block_start',index:0,content_block:tool},
      {type:'content_block_stop',index:0}, {type:'message_stop'},
    ].map(value=>`event: ${value.type}\ndata: ${JSON.stringify(value)}\n\n`).join(''), {headers:{'content-type':'text/event-stream'}});
  };
});
afterEach(() => {globalThis.fetch = realFetch;});
afterAll(async () => {await rm(directory,{recursive:true,force:true});});

for (const mode of ['freeFirst','trial','plan fallback']) {
  for (const streamed of [false,true]) {
    test(`ZCode ${mode} ${streamed ? 'SSE' : 'JSON'} preserves model identity and ToolSearch replies together`, async () => {
      stream = streamed; fallback = mode === 'plan fallback';
      const hooks = await plugin({client:{auth:{set:async()=>{}}}}, {freeFirst:mode !== 'trial'});
      const loader = await hooks.auth.loader(async()=>auth,{id:'zcode'});
      const response = await loader.fetch('https://api.z.ai/api/anthropic/v1/messages', {
        method:'POST', headers:{'content-type':'application/json'}, body:JSON.stringify({
          model:'GLM-5.3-Flash'+(mode === 'trial' ? '-Trial' : ''), max_tokens:100, stream,
          messages:[{role:'user',content:'hi'}],tools:[{name:'ToolSearch',input_schema:{type:'object',properties:{query:{type:'string'}}}}],
        }),
      });
      expect(response.status).toBe(200);
      expect(sent.at(-1).body.tools[0].name).toBe('ToolSearchTool');
      const expected = mode === 'plan fallback' ? 'glm-5.3-flash' : 'GLM-5.3-Flash-Trial';
      if (!stream) {
        const result = await response.json();
        expect(result.model).toBe(expected);
        expect(result.content[0].name).toBe('ToolSearch');
      } else {
        const frames = (await response.text()).split('\n').filter(line=>line.startsWith('data: ')).map(line=>JSON.parse(line.slice(6)));
        expect(frames.find(frame=>frame.type === 'message_start').message.model).toBe(expected);
        expect(frames.find(frame=>frame.type === 'content_block_start').content_block.name).toBe('ToolSearch');
      }
      expect(sent.at(-1).path).toBe(mode === 'plan fallback' ? '/api/anthropic/v1/messages' : '/api/v1/zcode-plan/anthropic/v1/messages');
    });
  }
}


test('ZCode Start Plan slots separate regions and share one regional UID across profiles', async () => {
  hold = true; fallback = false; stream = true;
  const responses = [];
  try {
    for (const [site, team] of [['bigmodel',false], ['zai',false], ['bigmodel',true]]) {
      const state = {...JSON.parse(auth.refresh), site, base: site === 'bigmodel' ? 'https://open.bigmodel.cn/api/anthropic' : 'https://api.z.ai/api/anthropic', ...(team ? {org:'org',project:'project'} : {})};
      const grant = {...auth,accountId:`${site}:official-a${team ? ' (team)' : ''}`,refresh:JSON.stringify(state)};
      const hooks = await plugin({client:{auth:{set:async()=>{}}}});
      const loader = await hooks.auth.loader(async()=>grant,{id:'zcode'});
      responses.push(await loader.fetch(state.base+'/v1/messages',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({model:'GLM-5.3-Flash-Trial',stream:true,max_tokens:16,messages:[{role:'user',content:'hi'}]})}));
    }
    expect(responses.map(r=>r.status)).toEqual([200,200,200]);
    expect(native.startGate.lanes.size).toBe(2);
    expect([...native.startGate.lanes.values()].map(lane=>lane.busy).sort()).toEqual([1,2]);
  } finally {
    for (const response of responses) await response.body?.cancel();
  }
});

test('ZCode expired reset cards are not counted even when the vendor flags them available', async () => {
  const list = {code:200,data:{
    fiveHourResets:[{available:true,expireTime:'2020-01-01 00:00:00'}],
    weekResets:[{available:true,expireTime:'2020-01-01 00:00:00'}],
  }};
  globalThis.fetch = async input => {
    const path = new URL(String(input)).pathname;
    if(path === '/api/biz/subscription/list') return Response.json({code:0,data:[]});
    if(path === '/api/monitor/usage/quota/limit') return Response.json({code:0,data:{level:'pro',limits:[]}});
    if(path === '/api/biz/customer-package-reset/list') return Response.json(list);
    throw new Error('Unexpected fixture endpoint '+path);
  };
  const hooks = await plugin();
  const getAuth = async()=>({type:'api',key:'glm-key',metadata:{site:'bigmodel'}});
  expect((await hooks.auth.usage(getAuth)).resets).toBeUndefined();
  list.data.weekResets.push({available:true,expireTime:'2099-01-01 23:59:59'});
  expect((await hooks.auth.usage(getAuth)).resets).toMatchObject({count:1,fiveHour:0,weekly:1});
});
