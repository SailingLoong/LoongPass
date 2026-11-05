import 'dart:async';
import '../lib/workbuddy_automatic.dart';
import '../lib/workbuddy_accounts.dart';
import '../lib/workbuddy_account_flow.dart';
import '../lib/workbuddy_api.dart';
import '../lib/workbuddy_claim.dart';
import 'workbuddy_multi_checks.dart' as fake;
void check(bool ok,String why){if(!ok)throw StateError(why);}
class Clock {
 final callbacks=<void Function()>[];final cancelled=<int>{};
 void Function() schedule(Duration _,void Function() callback){final n=callbacks.length;callbacks.add(callback);return()=>cancelled.add(n);}
 void fireEvenIfCancelled(){for(final c in List.of(callbacks)){c();}}
}
class Fixture {
 final rig=fake.Rig(),clock=Clock();late final WorkBuddyAccounts accounts;late final WorkBuddyAutomatic automatic;
 Fixture(List<fake.Server> servers){rig.queue.addAll(servers);accounts=rig.roster();automatic=WorkBuddyAutomatic(accounts,once:clock.schedule,periodic:clock.schedule);}
 Future<String> login()=>fake.login(accounts);
 void close(){automatic.close();accounts.close();}
}
class StatusServer extends fake.Server {
 bool eligible=false,needsLogin=false;Completer<void>? wait;
 StatusServer(super.uid);
 @override Future<Map<String,Object?>> send(WorkBuddyRequest r,bool Function() admitted)async{
  if(r.uri.path.endsWith('checkin-activity-status')){await wait?.future;if(needsLogin)return {'code':10085};if(!eligible){check(admitted(),'admitted status');requests.add(r);return {'code':0,'data':{'today_checked_in':false,'active':false}};}}
  return super.send(r,admitted);
 }
}
class BeforeSendServer extends fake.Server {
 final entered=Completer<void>(),release=Completer<void>();BeforeSendServer(super.uid);
 @override Future<Map<String,Object?>> send(WorkBuddyRequest r,bool Function() admitted)async{
  if(r.uri.path.endsWith('daily-checkin')){entered.complete();await release.future;if(!admitted())throw const WorkBuddyApiFailure('ExpiredAuthorization',mayHaveBeenSent:false);}
  return super.send(r,admitted);
 }
}
class BeforeStatusServer extends fake.Server {
 final entered=Completer<void>(),release=Completer<void>();BeforeStatusServer(super.uid);
 @override Future<Map<String,Object?>> send(WorkBuddyRequest r,bool Function() admitted)async{
  if(r.uri.path.endsWith('checkin-activity-status')){entered.complete();await release.future;if(!admitted())throw const WorkBuddyApiFailure('ExpiredAuthorization',mayHaveBeenSent:false);}
  return super.send(r,admitted);
 }
}
class PauseStore extends fake.Memory {
 final entered=Completer<void>(),release=Completer<void>();bool paused=false;
 @override Future<bool> compareAndSet(String key,int? revision,WorkBuddyAttempt next)async{
  if(!paused){paused=true;entered.complete();await release.future;}
  return super.compareAndSet(key,revision,next);
 }
}
class DailyServer extends fake.Server {
 DateTime today=DateTime.utc(2026,11,5,4);
 DateTime? claimedDay;
 DailyServer():super('daily');
 @override Future<Map<String,Object?>> send(WorkBuddyRequest r,bool Function() admitted)async{
  if(r.uri.path.endsWith('checkin-activity-status')){
   check(admitted(),'current daily request');requests.add(r);
   return {'code':0,'data':{'today_checked_in':claimedDay==today,'active':true}};
  }
  if(r.uri.path.endsWith('daily-checkin'))claimedDay=today;
  return super.send(r,admitted);
 }
}
Future<void> main()async{
 int pass=0,fail=0;
 Future<void> test(String name,Future<void> Function() f)async{try{await f();pass++;print('PASS $name');}catch(_){fail++;print('FAIL $name');}}
 await test('saved session can check in on a later day without reauthorization',()async{
  final server=DailyServer(),store=fake.Memory(),clock=Clock();
  // Complete balance is supplied by this fixture, independently of the status.
  final roster=WorkBuddyAccounts(create:()=>WorkBuddyAccountFlow(
   exchange:server,store:store,ownerGeneration:'daily-owner',isOwnerCurrent:()=>true,
   now:()=>server.today,readCompleteBalance:(subject)async=>(subject:subject,totalRemaining:10.0+20*server.posts)));
  final automatic=WorkBuddyAutomatic(roster,once:clock.schedule,periodic:clock.schedule);
  final id=await fake.login(roster);automatic.setEnabled(id,true);
  await automatic.tick();await automatic.tick();
  check(server.posts==1&&automatic.enabled(id),'today settled without disarming future days');
  server.today=server.today.add(const Duration(days:1));
  await automatic.tick();await automatic.tick();
  check(server.posts==2&&store.rows.values.single.day=='2026-11-06','next day uses the existing durable journal');
  check(server.requests.where((r)=>r.uri.path.endsWith('/auth/state')).length==1,'same grant retained');
  automatic.close();roster.close();
 });
 await test('default is off and construction/ticks do not send',()async{final a=fake.Server('A');final f=Fixture([a]);final id=await f.login();final count=a.requests.length;await f.automatic.tick();check(!f.automatic.enabled(id)&&a.requests.length==count&&f.clock.callbacks.isEmpty,'no implicit opt-in or timer');f.close();});
 await test('independent account opt-ins use the existing daily claim core',()async{final a=fake.Server('A'),b=fake.Server('B');final f=Fixture([a,b]);final ia=await f.login(),ib=await f.login();check(f.automatic.setEnabled(ia,true),'A opt-in');await f.automatic.tick();check(a.posts==1&&b.posts==0&&f.automatic.enabled(ia),'one attempt for today');check(f.automatic.setEnabled(ib,true),'B opt-in');await f.automatic.tick();await f.automatic.tick();check(a.posts==1&&b.posts==1,'each selected owner once');f.close();});
 await test('ineligible status remains GET only and can be checked later',()async{final a=StatusServer('A');final f=Fixture([a]);final id=await f.login();f.automatic.setEnabled(id,true);await f.automatic.tick();check(a.posts==0&&f.automatic.enabled(id)&&f.rig.memory.rows.isEmpty,'no intent while ineligible');a.eligible=true;await f.automatic.tick();check(a.posts==1,'later eligibility uses fresh status');f.close();});
 await test('unknown result disarms without replay and other accounts continue',()async{final a=fake.Server('A')..loseReceipt=true,b=fake.Server('B');final f=Fixture([a,b]);final ia=await f.login(),ib=await f.login();f.automatic.setEnabled(ia,true);f.automatic.setEnabled(ib,true);await f.automatic.tick();await f.automatic.tick();check(a.posts==1&&b.posts==1&&!f.automatic.enabled(ia),'unknown not retried and B independent');f.close();});
 await test('overlapping ticks never duplicate work',()async{final a=fake.Server('A')..claimWait=Completer<void>();final f=Fixture([a]);final id=await f.login();f.automatic.setEnabled(id,true);final tick=f.automatic.tick();while(a.posts==0){await Future<void>.delayed(Duration.zero);}await f.automatic.tick();check(a.posts==1,'one in-flight tick');a.claimWait!.complete();await tick;f.close();});
 await test('off during status wait prevents claim without closing account',()async{final a=StatusServer('A')..eligible=true..wait=Completer<void>();final f=Fixture([a]);final id=await f.login();f.automatic.setEnabled(id,true);final tick=f.automatic.tick();while(!f.accounts.accounts.single.busy){await Future<void>.delayed(Duration.zero);}f.automatic.setEnabled(id,false);a.wait!.complete();await tick;check(a.posts==0&&f.accounts.accounts.single.uid=='A','no POST and memory owner remains');await f.accounts.claim(id);check(a.posts==1,'explicit manual action remains separate');f.close();});
 await test('off at automatic status send boundary prevents the GET too',()async{final a=BeforeStatusServer('A');final f=Fixture([a]);final id=await f.login();final count=a.requests.length;f.automatic.setEnabled(id,true);final tick=f.automatic.tick();await a.entered.future;f.automatic.setEnabled(id,false);a.release.complete();await tick;check(a.requests.length==count&&a.posts==0,'no status dispatch after opt-out');f.close();});
 await test('off during intent persistence revokes automatic dispatch',()async{final a=fake.Server('A');final f=Fixture([a]);final store=PauseStore();f.rig.store=(_)=>store;final id=await f.login();f.automatic.setEnabled(id,true);final tick=f.automatic.tick();await store.entered.future;f.automatic.setEnabled(id,false);store.release.complete();await tick;check(a.posts==0&&store.rows.length==1,'possibly committed intent retained without POST');f.close();});
 await test('off at transport send boundary revokes automatic dispatch',()async{final a=BeforeSendServer('A');final f=Fixture([a]);final id=await f.login();f.automatic.setEnabled(id,true);final tick=f.automatic.tick();await a.entered.future;f.automatic.setEnabled(id,false);a.release.complete();await tick;check(a.posts==0&&f.rig.memory.rows.length==1,'send-time guard holds and intent remains');f.close();});
 await test('off after POST does not erase unknown intent or replay',()async{final a=fake.Server('A')..claimWait=Completer<void>();final f=Fixture([a]);final id=await f.login();f.automatic.setEnabled(id,true);final tick=f.automatic.tick();while(a.posts==0){await Future<void>.delayed(Duration.zero);}f.automatic.setEnabled(id,false);a.claimWait!.complete();await tick;await f.automatic.tick();check(a.posts==1&&f.rig.memory.rows.length==1,'one POST and preserved pending');f.close();});
 await test('timer registration is single and late callbacks after close are inert',()async{final a=fake.Server('A');final f=Fixture([a]);final id=await f.login();f.automatic.setEnabled(id,true);f.automatic.setEnabled(id,true);check(f.clock.callbacks.length==2,'one startup plus one periodic registration');final count=a.requests.length;f.automatic.close();f.clock.fireEvenIfCancelled();await Future<void>.delayed(Duration.zero);check(a.requests.length==count&&f.clock.cancelled.length==2,'late timer cannot send');f.accounts.close();});
 await test('removing one opted-in account does not redirect its tick',()async{final a=fake.Server('A'),b=fake.Server('B');final f=Fixture([a,b]);final ia=await f.login(),ib=await f.login();f.automatic.setEnabled(ia,true);f.accounts.remove(ia);f.accounts.select(ib);await f.automatic.tick();check(a.posts==0&&b.posts==0,'no fallback to selected B');check(f.clock.cancelled.length==2,'last removed account retires timers');f.close();});
 await test('cancelled timer callbacks cannot start a newer opt-in early',()async{final a=fake.Server('A');final f=Fixture([a]);final id=await f.login();f.automatic.setEnabled(id,true);final old=List.of(f.clock.callbacks);f.automatic.setEnabled(id,false);f.automatic.setEnabled(id,true);final count=a.requests.length;for(final c in old){c();}await Future<void>.delayed(Duration.zero);check(a.requests.length==count,'old timer epoch cannot run new policy');f.close();});
 await test('already claimed observation waits for the next day without a journal or POST',()async{final a=fake.Server('A')..posts=1;final f=Fixture([a]);final id=await f.login();f.automatic.setEnabled(id,true);await f.automatic.tick();check(a.posts==1&&f.automatic.enabled(id)&&f.rig.memory.rows.isEmpty,'already claimed is read only');f.close();});
 await test('new scheduler never restores automatic opt-in',()async{final a=fake.Server('A');final f=Fixture([a]);final id=await f.login();f.automatic.setEnabled(id,true);f.automatic.close();final next=WorkBuddyAutomatic(f.accounts,once:f.clock.schedule,periodic:f.clock.schedule);await next.tick();check(!next.enabled(id)&&a.posts==0,'new instance stays off');next.close();f.accounts.close();});
 await test('rejected authentication disarms without refreshing credentials',()async{final a=StatusServer('A')..needsLogin=true;final f=Fixture([a]);final id=await f.login();f.automatic.setEnabled(id,true);await f.automatic.tick();check(!f.automatic.enabled(id)&&a.posts==0,'needs verification cannot create renewal access');f.close();});
 await test('unknown session cannot be opted in',()async{final f=Fixture([]);check(!f.automatic.setEnabled('missing',true),'unknown identity');await f.automatic.tick();check(f.rig.created==0,'no factory discovery');f.close();});
 print('$pass passed; $fail failed; fake timers/exchanges only; no persistent opt-in or credential storage');if(fail>0)throw StateError('automatic suite failed');
}
