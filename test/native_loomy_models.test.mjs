import { afterEach, expect, test } from 'bun:test';
import { spawn } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';
import { LoomyAuthPlugin, _internal } from '../runtime/vendor/plugins/loomy/index.mjs';

const original = globalThis.fetch;
afterEach(() => { globalThis.fetch = original; });

test('Loomy advertises only remote reasoning tiers and preserves requested xhigh on the wire', async () => {
  const efforts = ['none','low','medium','high','xhigh'];
  const entry = {id:'Future',name:'Future',capabilities:{reasoning:true},reasoning_efforts:efforts,default_reasoning_effort:'low'};
  const sent = [];
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(String(input));
    if (url.pathname === '/api/v1/models') return Response.json({code:'000000',data:[entry]});
    if (url.pathname === '/api/v1/chat/completions') {
      sent.push(JSON.parse(init.body));
      return Response.json({choices:[]});
    }
    throw new Error('Unexpected fixture endpoint '+url.pathname);
  };
  const hooks = await LoomyAuthPlugin();
  const auth = {type:'oauth',access:'synthetic',refresh:'',expires:0};
  const models = await hooks.provider.models({id:'loomy',models:{}},{auth});
  expect(models.Future).toMatchObject({
    id:'Future',providerID:'loomy',api:{id:'Future',npm:'@ai-sdk/openai-compatible',url:'https://loomyad.xunfei.cn/api/v1'},
    capabilities:{reasoning:true},
  });
  expect(Object.keys(models.Future.variants ?? {})).toEqual(efforts);
  expect(models.Future.variants.xhigh).toEqual({reasoningEffort:'xhigh'});
  expect(models.Future.options).toMatchObject({reasoningEffort:'low'});
  expect(_internal.catalogModel({id:'Unknown',capabilities:{reasoning:true}}).config.variants).toBeUndefined();
  const loader = await hooks.auth.loader(async()=>auth);
  for (const reasoning of [{reasoning_effort:'xhigh'},{reasoning:{effort:'xhigh'}}]) {
    const response = await loader.fetch('https://fixture.invalid/chat/completions',{
      method:'POST',body:JSON.stringify({model:'Future',messages:[],...reasoning}),
    });
    expect(response.status).toBe(200);
    expect(sent.at(-1)).toMatchObject(reasoning);
  }
  for (const effort of ['none','xhigh']) {
    await loader.fetch('https://fixture.invalid/chat/completions',{
      method:'POST',headers:{'x-magpie-effort':effort},body:JSON.stringify({model:'Future',messages:[]}),
    });
    expect(sent.at(-1).reasoning_effort).toBe(effort);
  }
  await loader.fetch('https://fixture.invalid/chat/completions',{
    method:'POST',headers:{'x-magpie-effort':'xhigh'},body:JSON.stringify({model:'Future',reasoning_effort:'low',messages:[]}),
  });
  expect(sent.at(-1).reasoning_effort).toBe('low');
  await loader.fetch('https://fixture.invalid/chat/completions',{method:'POST',body:JSON.stringify({model:'Future',messages:[]})});
  expect(sent.at(-1).reasoning_effort).toBeUndefined();
});

test('Loomy live existing and new models retain usable native URLs and capabilities through host RPC', async () => {
  const directory = await mkdtemp(join(tmpdir(),'loongpass-loomy-catalog-'));
  const entry = join(directory,'entry.mjs');
  const entries = ['DeepSeek-V4.1-Flash','Fresh'].map(id=>({id,name:id,capabilities:{reasoning:true,function_calling:true,vision:false},context_window:1048576,max_tokens:384000,reasoning_efforts:['none','xhigh']}));
  await writeFile(entry, `globalThis.fetch = async input => {
    if (new URL(String(input)).pathname !== '/api/v1/models') throw new Error('Network forbidden');
    return Response.json({code:'000000',data:${JSON.stringify(entries)}});
  }; await import(${JSON.stringify(pathToFileURL(resolve('runtime/vendor/magpie/host.js')).href)});`);
  const child = spawn(process.execPath,[entry],{cwd:directory,env:{...process.env,HOME:directory,USERPROFILE:directory},stdio:['pipe','pipe','ignore']});
  const exited = new Promise(resolve=>child.once('exit',resolve));
  const lines = createInterface({input:child.stdout});
  const pending = new Map(); let next = 0;
  lines.on('line',line=>{
    const message = JSON.parse(line),p = pending.get(message.id);
    if (!p) return;
    clearTimeout(p.timer);pending.delete(message.id);
    if(message.error)p.reject(new Error(message.error.message));else p.resolve(message.result);
  });
  const rpc=(method,params={})=>new Promise((resolve,reject)=>{
    const id=++next,timer=setTimeout(()=>reject(new Error('RPC timeout')),4000);
    pending.set(id,{resolve,reject,timer});child.stdin.write(JSON.stringify({id,method,params})+'\n');
  });
  try {
    await rpc('init',{directory,authPath:join(directory,'plugin-auth.json'),plugins:[{spec:'fixture-loomy',target:resolve('runtime/vendor/plugins/loomy/index.mjs')}]});
    await rpc('import',{provider:'loomy',key:'loomy#synthetic',auth:{type:'oauth',uid:'synthetic',accountId:'synthetic',access:'synthetic',refresh:'',expires:0}});
    const rows=await rpc('providers');
    for(const id of ['DeepSeek-V4.1-Flash','Fresh']) {
      expect(rows[0].models.find(m=>m.id===id)).toMatchObject({
        apiId:id,npm:'@ai-sdk/openai-compatible',url:'https://loomyad.xunfei.cn/api/v1',reasoning:true,
        context:1048576,output:384000,variants:['none','xhigh'],image:false,imageSaid:true,
      });
    }
  } finally {
    child.stdin.end();const timer=setTimeout(()=>child.kill(),1500);
    await exited;clearTimeout(timer);lines.close();for(const p of pending.values())clearTimeout(p.timer);
    await rm(directory,{recursive:true,force:true});
  }
});
