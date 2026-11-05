import 'dart:async';
import '../lib/workbuddy_vault.dart';

int checks=0;
void check(bool ok,String label){if(!ok)throw StateError(label);checks++;print('PASS $label');}
class MemoryStore implements WorkBuddyVaultStore {
 final rows=<String,Map<String,Object?>>{};
 bool fail=false;
 @override Future<Map<String,Object?>?> read(String key)async{if(fail)throw StateError('unavailable');return rows[key]==null?null:Map.of(rows[key]!);}
 @override Future<bool> compareExchange(String key,int? expected,Map<String,Object?> value)async{
  if(fail)throw StateError('unavailable');if(rows[key]?['revision']!=expected)return false;rows[key]=Map.of(value);return true;
 }
}
class BarrierStore extends MemoryStore {
 Completer<void>? barrier;
 Completer<void>? started;
 @override Future<Map<String,Object?>?> read(String key)async{
  final result=await super.read(key);
  final wait=barrier;if(wait!=null){barrier=null;started!.complete();await wait.future;}
  return result;
 }
}
class CasBarrierStore extends MemoryStore {
 Completer<void>? paused,started;
 @override Future<bool> compareExchange(String key,int? expected,Map<String,Object?> value)async{
  final result=await super.compareExchange(key,expected,value);
  if(paused!=null){final wait=paused!;paused=null;started!.complete();await wait.future;}
  return result;
 }
}
class CommitThenThrow extends MemoryStore {
 bool first=true;
 @override Future<bool> compareExchange(String key,int? expected,Map<String,Object?> value)async{
  final ok=await super.compareExchange(key,expected,value);
  if(first){first=false;throw StateError('synthetic readback failure after commit');}return ok;
 }
}
Future<void> main()async{
 final store=MemoryStore();final vault=WorkBuddyVault(store,now:()=>DateTime.utc(2026,11,5));
 const a='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
 const b='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
 WorkBuddyVaultCredential credential(String uid)=>WorkBuddyVaultCredential(domain:'www.workbuddy.cn',endpoint:'www.workbuddy.cn',uid:uid,accessToken:'synthetic-access-$uid',refreshToken:'synthetic-refresh-$uid',expiresAt:DateTime.utc(2026,11,6));
 await vault.save(a,credential('A'));await vault.save(b,credential('B'));
 final lease=await vault.restore(a,verify:(c,admitted)async=>c.uid=='A');
 check(lease!=null&&lease.current,'verified restoration');
 check(!lease!.automaticEnabled,'restoration never opts into automatic');
 check((await vault.restore(b,verify:(c,admitted)async=>c.uid=='B'))!=null,'independent account');
 check((await vault.restore(a,verify:(c,admitted)async=>false))==null,'profile mismatch refuses restore');
 check(!lease.current,'new restore retires older lease');
 final live=await vault.restore(a,verify:(c,admitted)async=>true);
 final ticket=await vault.beginRotation(a);
 check(!live!.current,'rotation retires live lease before use');
 check(await vault.restore(a,verify:(c,admitted)async=>true)==null,'pending rotation cannot restore');
 final restarted=WorkBuddyVault(store,now:()=>DateTime.utc(2026,11,5));
 check(await restarted.restore(a,verify:(c,admitted)async=>true)==null,'uncertain rotation survives restart');
 check(await vault.beginRotation(a)==null,'no repeat rotation while unknown');
 check(!await vault.save(a,credential('A')),'save cannot replace unresolved rotation');
 check(await vault.completeRotation(ticket!,credential('A')),'known rotation commits once');
 check(!await vault.completeRotation(ticket,credential('A')),'rotation completion cannot repeat');
 check(await vault.restore(a,verify:(c,admitted)async=>true)!=null,'new verified token restores');
 await vault.revoke(a);
 check(await vault.restore(a,verify:(c,admitted)async=>true)==null,'revoked cannot restore');
 check(!store.rows[a]!.containsKey('accessToken')&&!store.rows[a]!.containsKey('refreshToken'),'local revoke erases credential material');
 check(store.rows[b]!['state']=='active','revoke isolated by account');
 check(await restarted.restore(a,verify:(c,admitted)async=>true)==null,'revocation survives restart');
 check(!await vault.save(a,credential('A')),'tombstone requires explicit future reauthorization design');
 final lb=await vault.restore(b,verify:(c,admitted)async=>true);store.fail=true;
 try{await vault.revoke(b);}catch(_){}
 check(!lb!.current,'failed revocation still retires memory access');
 check(await vault.restore(b,verify:(c,admitted)async=>true)==null,'unavailable store fails closed');
 store.fail=false;
 final expired=WorkBuddyVault(store,now:()=>DateTime.utc(2026,11,7));var calls=0;
 check(await expired.restore(b,verify:(c,admitted)async{calls++;return true;})==null&&calls==0,'expired token no network verifier');
 store.rows[b]!['endpoint']='evil.invalid';
 check(await vault.restore(b,verify:(c,admitted)async=>true)==null,'corrupt endpoint rejected');
 try{await vault.save('../unsafe',credential('X'));check(false,'bad key');}catch(_){check(true,'invalid key refused');}
 check(!credential('A').toString().contains('synthetic'),'credential diagnostic redacted');
 final closed=WorkBuddyVault(MemoryStore());closed.close();
 check(!await closed.save(a,credential('A')),'closed vault cannot save new key');
 check(await closed.restore(a,verify:(c,admitted)async=>true)==null,'closed vault cannot restore new key');
 final raceStore=BarrierStore();
 final owner=WorkBuddyVault(raceStore,now:()=>DateTime.utc(2026,11,5));
 final paused=Completer<void>();raceStore.barrier=paused;raceStore.started=Completer<void>();
 final save=owner.save(a,credential('A'));await raceStore.started!.future;
 await owner.revoke(a);paused.complete();
 check(!await save,'save waiting on read cannot defeat revoke');
 check(await WorkBuddyVault(raceStore).restore(a,verify:(c,admitted)async=>true)==null,'missing-record tombstone survives new owner');
 final verifyStore=BarrierStore();final verifying=WorkBuddyVault(verifyStore,now:()=>DateTime.utc(2026,11,5));
 await verifying.save(a,credential('A'));
 final pauseVerify=Completer<void>();verifyStore.barrier=pauseVerify;verifyStore.started=Completer<void>();
 var verifyCalls=0;
 final pendingRestore=verifying.restore(a,verify:(c,admitted)async{verifyCalls++;return admitted();});
 await verifyStore.started!.future;verifying.close();pauseVerify.complete();
 check(await pendingRestore==null&&verifyCalls==0,'closed during read never dispatches verifier');
 final other=WorkBuddyVault(verifyStore,now:()=>DateTime.utc(2026,11,5));
 final otherLease=await other.restore(a,verify:(c,admitted)async=>admitted());
 await WorkBuddyVault(verifyStore).revoke(a);
 check(!await otherLease!.checkCurrent(),'cross-owner durable revoke detected before dispatch');
 final admitStore=MemoryStore();final admit=WorkBuddyVault(admitStore,now:()=>DateTime.utc(2026,11,5));
 await admit.save(a,credential('A'));final entered=Completer<void>(),release=Completer<void>();var dispatched=false;
 final restoring=admit.restore(a,verify:(c,admitted)async{entered.complete();await release.future;dispatched=admitted();return dispatched;});
 await entered.future;await admit.revoke(a);release.complete();
 check(await restoring==null&&!dispatched,'verifier dispatch admission closes during await');
 final cas=CasBarrierStore();final casOwner=WorkBuddyVault(cas,now:()=>DateTime.utc(2026,11,5));
 await casOwner.save(a,credential('A'));final rotationPause=Completer<void>();cas.paused=rotationPause;cas.started=Completer<void>();
 final rotating=casOwner.beginRotation(a);await cas.started!.future;casOwner.close();rotationPause.complete();
 check(await rotating==null,'close during rotation CAS cannot return ticket');
 check(cas.rows[a]!['state']=='rotationPending','interrupted rotation retains uncertainty marker');
 final cs=CasBarrierStore();final closedSave=WorkBuddyVault(cs);final savePause=Completer<void>();cs.paused=savePause;cs.started=Completer<void>();
 final saving=closedSave.save(a,credential('A'));await cs.started!.future;closedSave.close();savePause.complete();
 check(!await saving,'close during save CAS cannot imply current permission');
 check(cs.rows[a]!['state']=='revoked','save completed after close removes persisted credential material');
 check(!otherLease.current,'durable revoke check permanently retires lease');
 final uncertain=CommitThenThrow();final uncertainOwner=WorkBuddyVault(uncertain,now:()=>DateTime.utc(2026,11,5));
 var failed=false;try{await uncertainOwner.save(a,credential('A'));}catch(_){failed=true;}
 check(failed,'committed then failed readback is never success');
 check(uncertain.rows[a]!['state']=='revoked','uncertain save removes exact committed credential');
 check(await WorkBuddyVault(uncertain,now:()=>DateTime.utc(2026,11,5)).restore(a,verify:(c,admitted)async=>true)==null,'uncertain save cannot restore in new owner');
 print('RESULT $checks checks');
}
