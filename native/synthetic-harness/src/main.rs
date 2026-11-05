//! Test-only stdin/stdout driver. Owns fresh synthetic files; no production path,
//! credential input, HTTP, application launch, or product UI registration exists.
use loongpass_zcode_promotions_candidate::promotions::{Endpoint,Failure,Mode,Request,Store,Transport,Worker};
use loongpass_zcode_switch_candidate::ffi;
use serde_json::{json,Value};
use std::{collections::{BTreeMap,BTreeSet},ffi::{c_void,CStr},fs,io::{BufRead,Write},os::unix::fs::PermissionsExt,path::PathBuf,sync::atomic::{AtomicI32,Ordering}};
static STOPPED:AtomicI32=AtomicI32::new(1);
unsafe extern "C" fn stopped(_: *mut c_void)->i32 {STOPPED.load(Ordering::SeqCst)}
struct FixtureStore(PathBuf);
impl Store for FixtureStore {
 fn load(&mut self,_:&str)->Result<Option<Vec<u8>>,Failure>{match fs::read(&self.0){Ok(b)=>Ok(Some(b)),Err(e) if e.kind()==std::io::ErrorKind::NotFound=>Ok(None),Err(_)=>Err(Failure::Storage)}}
 fn persist(&mut self,_:&str,bytes:&[u8])->Result<(),Failure>{let temp=self.0.with_extension("tmp");let mut f=fs::File::create(&temp).map_err(|_|Failure::Storage)?;f.write_all(bytes).and_then(|_|f.sync_all()).map_err(|_|Failure::Storage)?;fs::rename(&temp,&self.0).map_err(|_|Failure::Storage)?;fs::File::open(self.0.parent().unwrap()).and_then(|d|d.sync_all()).map_err(|_|Failure::Storage)?;if fs::read(&self.0).map_err(|_|Failure::Storage)?!=bytes{return Err(Failure::Storage)}Ok(())}
}
#[derive(Default)]struct Server{scenario:String,active:bool,posts:usize,calls:Vec<String>}
impl Transport for Server {
 fn send(&mut self,r:Request)->Result<Value,Failure>{
 self.calls.push(format!("{:?}",r.endpoint));
 match r.endpoint{
 Endpoint::Balance=>Ok(json!({"code":0,"data":{"server_time":100,"plans":if self.active{json!([{"plan_id":"synthetic-midnight-weekend","user_plan_id":"synthetic-new-instance","status":"active","ends_at":200}])}else{json!([])}}})),
 Endpoint::Preview=>Ok(json!({"code":0,"data":{"plans":[{"plan_id":"synthetic-midnight-weekend","name":"Synthetic promotion","priority":1}]}})),
 Endpoint::Claim=>{self.posts+=1;match self.scenario.as_str(){"timeout"=>Err(Failure::Transport),"captcha"=>Ok(json!({"code":3007})),_=>Ok(json!({"code":0,"data":{"plan":{"plan_id":"synthetic-midnight-weekend","user_plan_id":"synthetic-new-instance","starts_at":100,"ends_at":200}}}))}}
 }
 }
}
struct App {root:tempfile::TempDir,session:u64,known:BTreeSet<String>,servers:BTreeMap<String,Server>,worker:Worker}
impl App {
 fn new()->Self{
 let root=tempfile::tempdir().unwrap();let source=root.path().join("credentials.json");let target=root.path().join("saved.json");let backup=root.path().join("backups");fs::create_dir(&backup).unwrap();fs::set_permissions(&backup,fs::Permissions::from_mode(0o700)).unwrap();
 for (path,data) in [(&source,include_bytes!("../fixtures/a.json").as_slice()),(&target,include_bytes!("../fixtures/b.json").as_slice())]{fs::write(path,data).unwrap();fs::set_permissions(path,fs::Permissions::from_mode(0o600)).unwrap();}
 let config=serde_json::to_vec(&json!({"source":source,"backupRoot":backup,"context":"synthetic-integrated-context","secret":"SYNTHETIC-INTEGRATED-SECRET"})).unwrap();
 let session=unsafe{ffi::lp_zcode_open(config.as_ptr(),config.len(),Some(stopped),std::ptr::null_mut())};assert_ne!(session,0);
 Self{root,session,known:BTreeSet::new(),servers:BTreeMap::new(),worker:Worker::approved_plans(["synthetic-midnight-weekend".into()]).unwrap()}
 }
 fn native(&self,value:&Value)->Value{let bytes=serde_json::to_vec(value).unwrap();unsafe{let ptr=ffi::lp_zcode_call(self.session,bytes.as_ptr(),bytes.len());assert!(!ptr.is_null());let reply=serde_json::from_slice(CStr::from_ptr(ptr).to_bytes()).unwrap();ffi::lp_zcode_free(ptr);reply}}
 fn execute(&mut self,mut request:Value)->Value{
 let method=request.get("method").and_then(Value::as_str).unwrap_or("").to_owned();
 match method.as_str(){
 "requestStop"=>{STOPPED.store(0,Ordering::SeqCst);self.native(&json!({"method":"status"}))},
 "reopen"=>{STOPPED.store(1,Ordering::SeqCst);self.native(&json!({"method":"status"}))},
 "promotionStatus"=>json!({"available":true,"reason":null}),
 "previewPromotions"|"claimPromotions"=>{
 let Some(account)=request.get("accountId").and_then(Value::as_str).filter(|id|self.known.contains(*id)).map(str::to_owned)else{return json!({"error":"UnknownAccount"})};
 let storepath=self.root.path().join(format!("promotion-{account}.json"));let server=self.servers.entry(account.clone()).or_default();let mode=if method=="previewPromotions"{Mode::Preview}else{Mode::Claim};
 match self.worker.run(&account,mode,100,&mut FixtureStore(storepath),server,&mut ||Ok(())){
 Ok(mut view)=>{view.as_object_mut().unwrap().retain(|key,_|["status","canClaim","planId","planName","reason","startsAt","endsAt","checkedAt","windowPolicy","exactOfferWindow"].contains(&key.as_str()));view},
 Err(_)=>json!({"error":"Storage"})}
 },
 "testScenario"=>{let account=request["accountId"].as_str().unwrap().to_owned();if !self.known.contains(&account){return json!({"error":"UnknownAccount"})};let server=self.servers.entry(account).or_default();server.scenario=request["scenario"].as_str().unwrap().to_owned();server.active=request["active"].as_bool().unwrap_or(false);json!({"ok":true})},
 "testCounters"=>json!({"accounts":self.servers.iter().map(|(id,s)|(id.clone(),json!({"posts":s.posts,"calls":s.calls}))).collect::<BTreeMap<_,_>>(),"sourceRestored":fs::read(self.root.path().join("credentials.json")).unwrap()==include_bytes!("../fixtures/a.json")}),
 "captureCurrent"|"captureSelected"=>{if method=="captureSelected"{request["path"]=json!(self.root.path().join("saved.json"));}let value=self.native(&request);if let Some(id)=value["accountId"].as_str(){self.known.insert(id.into());}value},
 "restoreSelected"=>{let Some(path)=fs::read_dir(self.root.path().join("backups")).unwrap().next().map(|e|e.unwrap().path())else{return json!({"error":"Cancelled"})};request["path"]=json!(path);self.native(&request)},
 "status"|"switchAccount"|"restore"=>self.native(&request),
 _=>json!({"error":"UnsupportedMethod"}),
 }
 }
}
impl Drop for App{fn drop(&mut self){ffi::lp_zcode_close(self.session)}}
fn main(){let mut app=App::new();let stdin=std::io::stdin();let mut stdout=std::io::stdout();for line in stdin.lock().lines(){let Ok(line)=line else{break};if line.len()>65536{break}let reply=match serde_json::from_str(&line){Ok(value)=>app.execute(value),Err(_)=>json!({"error":"InvalidArguments"})};writeln!(stdout,"{}",reply).unwrap();stdout.flush().unwrap();}}
