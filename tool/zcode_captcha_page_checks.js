const assert={
  ok(value){if(!value)throw new Error('expected truthy value')},
  equal(actual,expected,message='values differ'){if(actual!==expected)throw new Error(message)},
  deepEqual(actual,expected){if(JSON.stringify(actual)!==JSON.stringify(expected))throw new Error('events differ')},
};
async function scenario(kind){
  const events=[], timers=new Map(), elements=new Map();
  let options, started=0, clicks=0, next=0;
  const element=id=>{if(!elements.has(id))elements.set(id,{hidden:true,click(){clicks++}});return elements.get(id)};
  const context={
    window:{webkit:{messageHandlers:{zcodeVerification:{postMessage:v=>events.push(v)}}},initAliyunCaptcha:o=>{options=o}},
    document:{getElementById:element,createElement:()=>({}),head:{appendChild:s=>s.onload()}},
    setTimeout:(fn,ms)=>{const id=++next;timers.set(id,{fn,ms});return id},clearTimeout:id=>timers.delete(id),
  };
  new Function('window','document','setTimeout','clearTimeout',source)(context.window,context.document,context.setTimeout,context.clearTimeout);
  await Promise.resolve();await Promise.resolve();
  assert.ok(options);
  const instance=kind==='interactive'?{show(){}}:{startTracelessVerification(){started++}};
  options.getInstance(instance);
  function advance(ms){for(const [id,t] of [...timers])if(t.ms===ms){timers.delete(id);t.fn()}}
  if(kind==='cancel')element('cancel').onclick();
  advance(2200);
  if(kind==='success'){options.success('synthetic-proof');options.success('duplicate-proof')}
  if(kind==='network')options.onError({code:'synthetic'});
  if(kind==='challenge')options.fail({code:'synthetic'});
  advance(12000);
  assert.equal(clicks,0,'never simulate a click');
  if(kind==='success'){
    assert.equal(started,1);assert.deepEqual(events.map(x=>x.type),['proof']);
    assert.equal(events[0].param,'synthetic-proof');
  }else if(kind==='network'||kind==='timeout')assert.deepEqual(events.map(x=>x.type),['unavailable']);
  else if(kind==='cancel'){assert.equal(started,0);assert.deepEqual(events.map(x=>x.type),['cancel'])}
  else{
    assert.deepEqual(events.map(x=>x.type),['interactive']);
    options.success({captchaVerifyParam:'human-proof'});
    assert.equal(events[1].type,'proof');
    assert.equal(events[1].param,'human-proof');
  }
}
var completed=false, failure=null;
(async()=>{
  for(const kind of ['success','interactive','challenge','timeout','network','cancel'])await scenario(kind);
})().then(()=>completed=true).catch(error=>{failure=String(error);completed=true});
