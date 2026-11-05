import 'dart:async';
import 'dart:io';
import '../lib/workbuddy_accounts.dart';
import '../lib/workbuddy_account_flow.dart';
import '../lib/workbuddy_api.dart';
import '../lib/workbuddy_claim.dart';
import '../lib/workbuddy_attempt_journal.dart';

void check(bool ok,String why){if(!ok)throw StateError(why);}
class Memory implements WorkBuddyAttemptStore {
 final rows=<String,WorkBuddyAttempt>{};
 Future<WorkBuddyAttempt?> read(String key)async=>rows[key];
 Future<bool> compareAndSet(String key,int? revision,WorkBuddyAttempt next)async{if(rows[key]?.revision!=revision)return false;rows[key]=next;return true;}
}
class Server implements WorkBuddyExchange {
 final String uid,domain;
 final requests=<WorkBuddyRequest>[];
 Completer<void>? tokenWait,claimWait,stateWait;
 bool pending=false,loseReceipt=false;
 int posts=0;
 Server(this.uid,{this.domain='www.workbuddy.cn'});
 Future<Map<String,Object?>> send(WorkBuddyRequest r,bool Function() admitted)async{
  check(admitted(),'current before synthetic exchange');requests.add(r);
  if(r.uri.path.endsWith('/auth/state')){await stateWait?.future;return {'code':0,'data':{'state':'state-$domain-$uid','authUrl':'https://www.workbuddy.cn/login?state=state-$domain-$uid'}};}
  if(r.uri.path.endsWith('/auth/token')){check(r.uri.queryParameters['state']=='state-$domain-$uid','state belongs to this owner');await tokenWait?.future;return pending?{'code':11217}:{'code':0,'data':{'accessToken':'synthetic-token-$domain-$uid','domain':domain}};}
  check(r.headers['Authorization']=='Bearer synthetic-token-$domain-$uid'&&r.headers['X-Domain']==domain,'bearer/domain cannot cross account owners');
  if(r.uri.path=='/v2/plugin/account')return {'code':0,'data':{'uid':uid,'domain':domain,'type':'personal'}};
  if(r.uri.path.endsWith('/daily-checkin')){posts++;await claimWait?.future;if(loseReceipt)throw StateError('SYNTHETIC-CANARY');return {'code':0,'credit':20};}
  if(r.uri.path.endsWith('/checkin-activity-status'))return {'code':0,'data':{'today_checked_in':posts>0,'active':true}};
  throw StateError('unexpected route');
 }
}
class Rig {
 final queue=<Server>[];final Memory memory=Memory();int created=0;
 WorkBuddyAttemptStore Function(WorkBuddyAccountFlow)? store;
 final flows=<WorkBuddyAccountFlow>[];String prefix='synthetic';
 WorkBuddyAccountFlow create(){final server=queue.removeAt(0);late WorkBuddyAccountFlow flow;final generation='$prefix-owner-${++created}';
  flow=WorkBuddyAccountFlow(exchange:server,ownerGeneration:generation,isOwnerCurrent:()=>true,store:store==null?memory:_LateStore(()=>store!(flow)),now:()=>DateTime.utc(2026,11,5,4),readCompleteBalance:(subject)async=>(subject:subject,totalRemaining:server.posts==0?10.0:30.0));flows.add(flow);return flow;
 }
 WorkBuddyAccounts roster()=>WorkBuddyAccounts(create:create);
}
// Lazily binds each real journal to its owning flow. No mock storage is used in
// the restart test, except the explicitly labeled native-directory-sync seam.
class _LateStore implements WorkBuddyAttemptStore {
 final WorkBuddyAttemptStore Function() get;WorkBuddyAttemptStore? _inner;_LateStore(this.get);
 WorkBuddyAttemptStore get inner=>_inner??=get();
 Future<WorkBuddyAttempt?> read(String k)=>inner.read(k);
 Future<bool> compareAndSet(String k,int? r,WorkBuddyAttempt n)=>inner.compareAndSet(k,r,n);
}
Future<String> login(WorkBuddyAccounts r)async{final grant=await r.beginAuthorization();check(grant!=null,'grant');await r.poll(grant!.sessionId);check(r.accounts.any((a)=>a.id==grant.sessionId),'verified account attached');return grant.sessionId;}
Future<void> processPhase(String phase,String path)async{
 final root=Directory(path);check(await root.resolveSymbolicLinks()==root.path,'canonical synthetic root');
 final a=Server('A')..loseReceipt=true,b=Server('B');final rig=Rig()..prefix=phase..queue.addAll([a,b]);
 rig.store=(flow)=>WorkBuddyAttemptJournal(root,syncDirectory:()async{},isCurrent:flow.isCurrent);
 final roster=rig.roster();final ia=await login(roster),ib=await login(roster);await roster.claim(ia);await roster.claim(ib);roster.close();
 check(a.posts==(phase=='--seed'?1:0)&&b.posts==(phase=='--seed'?1:0),'only seed process may post');
 print('synthetic child $phase completed without credential output');
}
Future<void> main(List<String> args)async{
 if(args.length==2&&['--seed','--resume'].contains(args[0])){await processPhase(args[0],args[1]);return;}

 int passed=0,failed=0;
 Future<void> test(String name,Future<void> Function() f)async{try{await f();passed++;print('PASS $name');}catch(_){failed++;print('FAIL $name');}}
 await test('construction is lazy',()async{final rig=Rig();final r=rig.roster();check(rig.created==0&&r.sessions.isEmpty,'no I/O on construction');r.close();});
 await test('two independent authorization sessions become two accounts',()async{final a=Server('A'),b=Server('B');final rig=Rig()..queue.addAll([a,b]);final r=rig.roster();final ga=(await r.beginAuthorization())!,gb=(await r.beginAuthorization())!;check(ga.sessionId!=gb.sessionId&&r.pending.length==2,'pending sessions distinct');await r.poll(gb.sessionId);await r.poll(ga.sessionId);check(r.accounts.length==2&&r.pending.isEmpty,'two profile verified accounts');r.close();});
 await test('selection performs no exchange and results stay on the original account',()async{final a=Server('A'),b=Server('B');final rig=Rig()..queue.addAll([a,b]);final r=rig.roster();final ia=await login(r),ib=await login(r);final count=a.requests.length+b.requests.length;r.select(ia);check(a.requests.length+b.requests.length==count,'selection is local');await r.claim(ia);r.select(ib);check(r.selected?.uid=='B'&&r.selected?.result==null,'B cannot inherit A result');check(r.accounts.firstWhere((s)=>s.id==ia).result?.state==WorkBuddyState.claimed&&a.posts==1&&b.posts==0,'A result and single post');r.close();});
 await test('pending cancellation affects only that session',()async{final a=Server('A'),b=Server('B')..pending=true;final rig=Rig()..queue.addAll([a,b]);final r=rig.roster();final ia=await login(r);final pending=(await r.beginAuthorization())!;r.cancelAuthorization(pending.sessionId);await r.poll(pending.sessionId);check(r.accounts.single.id==ia&&b.requests.length==1,'A preserved and B never polled');r.close();});
 await test('cancel during token wait cannot attach a late profile',()async{final a=Server('A')..tokenWait=Completer<void>();final rig=Rig()..queue.add(a);final r=rig.roster();final g=(await r.beginAuthorization())!;final wait=r.poll(g.sessionId);r.cancelAuthorization(g.sessionId);a.tokenWait!.complete();await wait;check(r.accounts.isEmpty&&a.requests.length==2,'no late profile');r.close();});
 await test('close during asynchronous creation retires the returned owner',()async{final server=Server('A');final rig=Rig()..queue.add(server);final created=Completer<WorkBuddyAccountFlow>();final r=WorkBuddyAccounts(create:()=>created.future);final waiting=r.beginAuthorization();r.close();created.complete(rig.create());check(await waiting==null&&server.requests.isEmpty&&rig.flows.single.uid==null,'no late authorization dispatch');});
 await test('duplicate verified identity is rejected without replacing or retiring the first owner',()async{final a=Server('A'),duplicate=Server('A');final rig=Rig()..queue.addAll([a,duplicate]);final r=rig.roster();final first=await login(r);final second=(await r.beginAuthorization())!;await r.poll(second.sessionId);check(r.accounts.length==1&&r.accounts.single.id==first&&r.selected?.uid=='A','first owner preserved');await r.claim(first);check(a.posts==1&&duplicate.posts==0,'only existing account is claimable');r.close();});
 await test('same UID on separate domains remains independently scoped',()async{final a=Server('A'),b=Server('A',domain:'www.codebuddy.cn');final rig=Rig()..queue.addAll([a,b]);final r=rig.roster();final ia=await login(r),ib=await login(r);await r.claim(ia);await r.claim(ib);check(r.accounts.length==2&&a.posts==1&&b.posts==1&&rig.memory.rows.length==2,'domain scoped owners and receipts');r.close();});
 await test('reused factory instance cannot retire the existing verified account',()async{final a=Server('A');final rig=Rig()..queue.add(a);final owner=rig.create();final r=WorkBuddyAccounts(create:()=>owner);final id=await login(r);check(await r.beginAuthorization()==null&&r.accounts.single.id==id&&r.accounts.single.uid=='A','reused object refused without close');r.close();});
 await test('unknown A does not block B or permit A to replay',()async{final a=Server('A')..loseReceipt=true,b=Server('B');final rig=Rig()..queue.addAll([a,b]);final r=rig.roster();final ia=await login(r),ib=await login(r);await r.claim(ia);await r.claim(ia);await r.claim(ib);check(a.posts==1&&b.posts==1,'one dispatch per account');check(r.accounts.firstWhere((x)=>x.id==ia).result?.state==WorkBuddyState.unconfirmed&&r.accounts.firstWhere((x)=>x.id==ib).result?.state==WorkBuddyState.claimed,'independent unknown and confirmed results');r.close();});
 await test('claim entry is serialized rather than silently queued',()async{final a=Server('A')..claimWait=Completer<void>(),b=Server('B');final rig=Rig()..queue.addAll([a,b]);final r=rig.roster();final ia=await login(r),ib=await login(r);final action=r.claim(ia);while(a.posts==0){await Future<void>.delayed(Duration.zero);}r.select(ib);await r.claim(ib);check(b.posts==0&&r.selected?.uid=='B','B action not queued');a.claimWait!.complete();await action;await r.claim(ib);check(b.posts==1,'explicit later action permitted');r.close();});
 await test('removal closes only one memory owner and retains durable intent',()async{final a=Server('A')..loseReceipt=true,b=Server('B');final rig=Rig()..queue.addAll([a,b]);final r=rig.roster();final ia=await login(r),ib=await login(r);await r.claim(ia);final rows=Map.of(rig.memory.rows);r.remove(ia);check(r.accounts.single.id==ib&&rig.memory.rows.length==rows.length,'memory removal not journal deletion');await r.claim(ib);check(b.posts==1,'remaining owner alive');r.close();});
 await test('close after POST preserves unknown across reauthorization',()async{final a=Server('A')..claimWait=Completer<void>();final rig=Rig()..queue.add(a);final r=rig.roster();final id=await login(r);final action=r.claim(id);while(a.posts==0){await Future<void>.delayed(Duration.zero);}r.close();a.claimWait!.complete();await action;rig.queue.add(a);final next=rig.roster();final id2=await login(next);await next.claim(id2);check(a.posts==1&&rig.memory.rows.length==1,'no replay after close and reauthorization');next.close();});
 await test('unknown session IDs cannot target selected account implicitly',()async{final a=Server('A');final rig=Rig()..queue.add(a);final r=rig.roster();await login(r);final count=a.requests.length;await r.claim('missing');await r.poll('missing');await r.refreshStatus('missing');r.remove('missing');check(a.requests.length==count&&r.accounts.length==1,'no implicit fallback');r.close();});
 await test('flow verification cannot bypass roster admission',()async{final a=Server('A');final rig=Rig()..queue.add(a);final r=rig.roster();final g=(await r.beginAuthorization())!;await rig.flows.single.poll();check(r.accounts.isEmpty,'not admitted before roster deduplication');await r.claim(g.sessionId);check(a.posts==0,'unadmitted flow cannot claim');await r.poll(g.sessionId);check(r.accounts.length==1,'roster admission completes');r.close();});
 await test('nonfresh factory owner is refused without closing its other session',()async{final a=Server('A');final rig=Rig()..queue.add(a);final owner=rig.create();await owner.begin();final r=WorkBuddyAccounts(create:()=>owner);check(await r.beginAuthorization()==null&&owner.loginPending,'other pending owner preserved');r.close();owner.close();});
 await test('late nonfresh factory result cannot close another authorization',()async{final a=Server('A');final rig=Rig()..queue.add(a);final other=rig.create();await other.begin();final created=Completer<WorkBuddyAccountFlow>();final r=WorkBuddyAccounts(create:()=>created.future);final begin=r.beginAuthorization();r.close();created.complete(other);check(await begin==null&&other.loginPending,'late foreign owner remains intact');other.close();});
 await test('factory errors never expose arbitrary exception content',()async{final r=WorkBuddyAccounts(create:()=>throw StateError('SYNTHETIC-CANARY'));check(await r.beginAuthorization()==null&&!('${r.message}').contains('SYNTHETIC-CANARY'),'redacted factory failure');r.close();});
 await test('real journal restart preserves each account unknown receipt without credentials',()async{
  final created=await Directory.systemTemp.createTemp('loongpass-multi-');final root=Directory(await created.resolveSymbolicLinks());await Process.run('/bin/chmod',['700',root.path]);
  try{final a=Server('A')..loseReceipt=true,b=Server('B');final rig=Rig()..queue.addAll([a,b]);var syncs=0;rig.store=(flow)=>WorkBuddyAttemptJournal(root,syncDirectory:()async{syncs++;},isCurrent:flow.isCurrent);final r=rig.roster();final ia=await login(r),ib=await login(r);await r.claim(ia);await r.claim(ib);r.close();final file=File('${root.path}/workbuddy-intents.jsonl');final before=await file.readAsBytes();check(!String.fromCharCodes(before).contains('synthetic-token')&&syncs>0,'noncredential journal');rig.queue.addAll([a,b]);final next=rig.roster();final nia=await login(next),nib=await login(next);await next.claim(nia);await next.claim(nib);check(a.posts==1&&b.posts==1,'restart does not replay either record');check((await file.readAsBytes()).length==before.length,'unknown/settled history preserved');next.close();}
  finally{await root.delete(recursive:true);}
 });
 await test('separate Dart process reauthorization cannot replay either account',()async{final tmp=await Directory.systemTemp.createTemp('loongpass-multi-process-');final root=Directory(await tmp.resolveSymbolicLinks());await Process.run('/bin/chmod',['700',root.path]);try{final seed=await Process.run(Platform.resolvedExecutable,[Platform.script.toFilePath(),'--seed',root.path]);check(seed.exitCode==0,'seed process passed');final file=File('${root.path}/workbuddy-intents.jsonl');final before=await file.readAsBytes();final resume=await Process.run(Platform.resolvedExecutable,[Platform.script.toFilePath(),'--resume',root.path]);check(resume.exitCode==0,'resume process passed');final after=await file.readAsBytes();check(before.length==after.length&&before.asMap().entries.every((e)=>after[e.key]==e.value),'process restart leaves both original histories unchanged');}finally{await root.delete(recursive:true);}});
 print('$passed passed; $failed failed; fake exchanges and synthetic data only; directory-sync seam synthetic');if(failed>0)throw StateError('multi-account suite failed');
}
