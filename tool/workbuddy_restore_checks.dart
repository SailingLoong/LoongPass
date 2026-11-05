import '../lib/workbuddy_accounts.dart';
import '../lib/workbuddy_account_flow.dart';
import '../lib/workbuddy_api.dart';
import '../lib/workbuddy_vault.dart';
import '../lib/workbuddy_claim.dart';

class Store implements WorkBuddyVaultStore {
 final rows=<String,Map<String,Object?>>{};
 Future<Map<String,Object?>?> read(String key)async=>rows[key]==null?null:Map.of(rows[key]!);
 Future<bool> compareExchange(String key,int? expected,Map<String,Object?> value)async{if(rows[key]?['revision']!=expected)return false;rows[key]=Map.of(value);return true;}
}
class Exchange implements WorkBuddyExchange {
 int profile=0,status=0,posts=0;String? wrongUid;String authorizing='A';
 bool unknownExpiry=false;
 Future<Map<String,Object?>> send(WorkBuddyRequest r,bool Function() admitted)async{
  if(!admitted())throw const WorkBuddyApiFailure('ExpiredAuthorization',mayHaveBeenSent:false);
  if(r.uri.path.endsWith('/auth/state'))return {'code':0,'data':{'state':'state-$authorizing','authUrl':'https://www.workbuddy.cn/login?state=state-$authorizing'}};
  if(r.uri.path.endsWith('/auth/token'))return {'code':0,'data':{'accessToken':'synthetic-$authorizing','domain':'www.workbuddy.cn',if(!unknownExpiry)'expiresIn':3600}};
  if(r.uri.path=='/v2/plugin/account'){
   profile++;final uid=r.headers['Authorization']=='Bearer synthetic-A'?'A':'B';
   if(r.method!='GET'||r.headers.containsKey('X-User-Id'))throw StateError('profile request');
   return {'code':0,'data':{'uid':wrongUid??uid,'type':'personal','domain':'www.workbuddy.cn'}};
  }
  if(r.uri.path.endsWith('daily-checkin')){posts++;throw StateError('never claim in restore test');}
  status++;return {'code':0,'data':{'active':true,'today_checked_in':false}};
 }
}
class Attempts implements WorkBuddyAttemptStore {
 WorkBuddyAttempt? row;
 Future<WorkBuddyAttempt?> read(String key)async=>row;
 Future<bool> compareAndSet(String key,int? expected,WorkBuddyAttempt next)async{if(row?.revision!=expected)return false;row=next;return true;}
}
class BoundFlow extends WorkBuddyAccountFlow {
 final void Function() onBound;
 BoundFlow(WorkBuddyExchange exchange,this.onBound):super(exchange:exchange,ownerGeneration:'synthetic-bound',isOwnerCurrent:()=>true,now:()=>DateTime.utc(2026,11,5));
 @override Future<bool> bindSaved(WorkBuddyVault vault,String key,{required bool Function() admission})async{
  final result=await super.bindSaved(vault,key,admission:admission);onBound();return result;
 }
}
Future<void> main()async{
 int checks=0;void check(bool b,String name){if(!b)throw StateError(name);checks++;print('PASS $name');}
 final store=Store(),exchange=Exchange();final vault=WorkBuddyVault(store,now:()=>DateTime.utc(2026,11,5));
 WorkBuddyAccountFlow flow()=>WorkBuddyAccountFlow.inMemory(exchange:exchange,now:()=>DateTime.utc(2026,11,5));
 final accounts=WorkBuddyAccounts(create:flow);
 final a='a'*64,b='b'*64;
 WorkBuddyVaultCredential c(String uid)=>WorkBuddyVaultCredential(domain:'www.workbuddy.cn',endpoint:'www.workbuddy.cn',uid:uid,accessToken:'synthetic-$uid',expiresAt:DateTime.utc(2026,11,6));
 await vault.save(a,c('A'));await vault.save(b,c('B'));
 final sa=await accounts.restore(vault,a),sb=await accounts.restore(vault,b);
 check(sa!=null&&sb!=null&&accounts.accounts.length==2,'two stored identities enter roster via profile verification');
 check(exchange.profile==2&&exchange.posts==0,'restore is profile GET only, never check-in');
 check(accounts.accounts.map((s)=>s.uid).join(',')=='A,B','restored identities isolated');
 await accounts.refreshStatus(sa!);check(exchange.status==1,'restored flow status uses same API');
 await accounts.revokeStored(sa);check(accounts.accounts.length==1&&accounts.accounts.single.uid=='B','revoke retires only selected restored flow');
 check((await store.read(a))!['state']=='revoked','roster revoke persists local tombstone');
 check(await accounts.restore(vault,a)==null,'revoked identity cannot reenter roster');
 final before=exchange.status;await accounts.refreshStatus(sa);check(exchange.status==before,'retired session cannot send');
 final duplicate=await accounts.restore(vault,b);check(duplicate==null&&accounts.accounts.length==1,'duplicate restore preserves existing owner');
 exchange.wrongUid='wrong';final another=WorkBuddyAccounts(create:flow);
 check(await another.restore(WorkBuddyVault(store,now:()=>DateTime.utc(2026,11,5)),b)==null,'profile mismatch never admitted');
 exchange.wrongUid=null;
 accounts.close();check(await accounts.restore(vault,b)==null,'closed roster never restores');
 check(exchange.posts==0,'all restore and revoke checks have zero claim POSTs');
 final addStore=Store(),addVault=WorkBuddyVault(Store(),now:()=>DateTime.utc(2026,11,5));
 final savedVault=WorkBuddyVault(addStore,now:()=>DateTime.utc(2026,11,5));
 final adding=WorkBuddyAccounts(create:flow);
 exchange.authorizing='A';final first=(await adding.beginAuthorization())!;
 check(adding.accounts.isEmpty,'new authorization is invisible before profile/save');
 check(await adding.pollAndSave(first.sessionId,savedVault)!=null,'existing begin/poll saves verified first account');
 exchange.authorizing='B';final second=(await adding.beginAuthorization())!;
 check(await adding.pollAndSave(second.sessionId,savedVault)!=null,'second add uses same flow and saves separate identity');
 check(addStore.rows.length==2&&adding.accounts.length==2,'two additions have separate records and roster slots');
 check(WorkBuddyVault.accountKey('www.workbuddy.cn','A')!=WorkBuddyVault.accountKey('www.workbuddy.cn','B'),'UID participates in opaque account key');
 check(WorkBuddyVault.accountKey('www.workbuddy.cn','A')!=WorkBuddyVault.accountKey('www.codebuddy.cn','A'),'domain participates in opaque account key');
 savedVault.close();check(adding.accounts.length==2&&adding.accounts.every((s)=>!s.canClaim&&s.message=='授权已不可用，请重新授权此账号。'),'retired credentials keep known identity visible with an unavailable authorization');
 adding.close();final restored=WorkBuddyAccounts(create:flow);final restoreVault=WorkBuddyVault(addStore,now:()=>DateTime.utc(2026,11,5));
 final keyA=WorkBuddyVault.accountKey('www.workbuddy.cn','A'),keyB=WorkBuddyVault.accountKey('www.workbuddy.cn','B');
 check(await restored.restore(restoreVault,keyA)!=null&&await restored.restore(restoreVault,keyB)!=null,'new roster restores both added identities');
 exchange.unknownExpiry=true;final noExpiry=WorkBuddyAccounts(create:flow);final ne=(await noExpiry.beginAuthorization())!;
 check(await noExpiry.pollAndSave(ne.sessionId,addVault)!=null,'profile-verified token with unknown expiry remains restorable');exchange.unknownExpiry=false;
 final proof=flow();final original=c('A');check(await proof.restoreCredential(original,admission:()=>true),'synthetic flow verifies original credential');
 final mismatchVault=WorkBuddyVault(Store(),now:()=>DateTime.utc(2026,11,5));
 await mismatchVault.save(a,WorkBuddyVaultCredential(domain:original.domain,endpoint:original.endpoint,uid:original.uid,accessToken:'synthetic-different',expiresAt:original.expiresAt));
 final mismatch=await mismatchVault.restore(a,verify:(c,admitted)async=>true);
 check(!proof.attachRestoredLease(mismatch!),'same identity different token lease refused');proof.close();
 final attempts=Attempts()..row=WorkBuddyAttempt(revision:0,subject:WorkBuddySubject('www.workbuddy.cn','A','old-owner'),day:'2026-11-05',before:10);
 final coreRoster=WorkBuddyAccounts(create:()=>WorkBuddyAccountFlow(exchange:exchange,ownerGeneration:'restored-new',isOwnerCurrent:()=>true,store:attempts,now:()=>DateTime.utc(2026,11,5),readCompleteBalance:(s)async=>(subject:s,totalRemaining:10.0)));
 final ca=await coreRoster.restore(WorkBuddyVault(addStore,now:()=>DateTime.utc(2026,11,5)),keyA);
 await coreRoster.claim(ca!);await coreRoster.claim(ca);
 check(exchange.posts==0&&attempts.row!.revision==0,'restored unknown claim intent never resets or repeats POST');
 coreRoster.close();restored.close();noExpiry.close();
 final cancelStore=Store();
 final actualCancelVault=WorkBuddyVault(cancelStore,now:()=>DateTime.utc(2026,11,5));
 late WorkBuddyAccounts cancelled;
 cancelled=WorkBuddyAccounts(create:()=>BoundFlow(exchange,()=>cancelled.close()));
 final cg=(await cancelled.beginAuthorization())!;
 check(await cancelled.pollAndSave(cg.sessionId,actualCancelVault)==null&&cancelStore.rows.values.single['state']=='revoked'&&cancelled.accounts.isEmpty,'close after lease binding cannot admit or retain credential');
 print('RESULT $checks restore checks');
}
