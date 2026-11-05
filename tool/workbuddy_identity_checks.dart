import 'dart:async';
import 'dart:io';
import '../lib/workbuddy_account_flow.dart';
import '../lib/workbuddy_accounts.dart';
import '../lib/workbuddy_api.dart';
import '../lib/workbuddy_vault.dart';
import '../lib/workbuddy_automatic.dart';
import '../lib/workbuddy_claim.dart';

class Fake implements WorkBuddyExchange {
 final String uid;final calls=<WorkBuddyRequest>[];Completer<void>? waitToken;
 Fake(this.uid);
 Future<Map<String,Object?>> send(WorkBuddyRequest r,bool Function() admitted)async{
  if(!admitted())throw StateError('closed');calls.add(r);
  if(r.uri.path.endsWith('/auth/state'))return {'code':0,'data':{'state':'state-$uid','authUrl':'https://www.workbuddy.cn/login?state=state-$uid'}};
  if(r.uri.path.endsWith('/auth/token')){await waitToken?.future;return {'code':0,'data':{'accessToken':'synthetic-$uid','domain':'www.workbuddy.cn','expiresIn':3600}};}
  if(r.uri.path=='/v2/plugin/account')return {'code':0,'data':{'uid':uid,'domain':'www.workbuddy.cn','type':'personal'}};
  throw StateError('unexpected request reached fake');
 }
}
class NeverStore implements WorkBuddyVaultStore {
 int calls=0;
 Future<Map<String,Object?>?> read(String k)async{calls++;throw StateError('storage forbidden');}
 Future<bool> compareExchange(String k,int? revision,Map<String,Object?> v)async{calls++;throw StateError('storage forbidden');}
}
class NoAttempts implements WorkBuddyAttemptStore {
 Future<WorkBuddyAttempt?> read(String k)async=>throw StateError('journal forbidden');
 Future<bool> compareAndSet(String k,int? revision,WorkBuddyAttempt row)async=>throw StateError('journal forbidden');
}
Future<void> main()async{
 int checks=0,clients=0;void check(bool b,String name){if(!b)throw StateError(name);checks++;print('PASS $name');}
 final a=Fake('A'),b=Fake('B'),queue=[a,b];final owners=<WorkBuddyAccountFlow>[];
 final roster=WorkBuddyAccounts(create:(){final f=WorkBuddyAccountFlow.inMemory(exchange:queue.removeAt(0),identityValidationOnly:true,now:()=>DateTime.utc(2026,11,5));owners.add(f);return f;});
 final ga=(await roster.beginAuthorization())!,gb=(await roster.beginAuthorization())!;
 check(a.calls.length==1&&b.calls.length==1,'two isolated authorization states');
 await roster.poll(gb.sessionId);await roster.poll(ga.sessionId);
 check(roster.accounts.length==2&&roster.accounts.map((s)=>s.uid).toSet().containsAll({'A','B'}),'two identities admitted independently');
 check(a.calls[1].uri.queryParameters['state']=='state-A'&&b.calls[1].uri.queryParameters['state']=='state-B','token polls use correct state');
 check(a.calls.last.headers['Authorization']=='Bearer synthetic-A'&&b.calls.last.headers['Authorization']=='Bearer synthetic-B','profile bearer isolated by owner');
 check(roster.accounts.every((s)=>!s.canClaim&&!s.claimOwnerAvailable),'identity owners cannot claim or enable automatic');
 int timers=0;
 final automatic=WorkBuddyAutomatic(roster,once:(_,__) {timers++;return (){};},periodic:(_,__) {timers++;return (){};});
 check(!automatic.setEnabled(ga.sessionId,true)&&timers==0,'identity owner cannot schedule automatic work');automatic.close();
 var storageDenied=false;
 try{WorkBuddyAccountFlow.inMemory(exchange:a,identityValidationOnly:true,store:NoAttempts());}on WorkBuddyFailure{storageDenied=true;}
 check(storageDenied,'identity construction rejects journal dependency');
 final before=a.calls.length+b.calls.length;
 await roster.refreshStatus(ga.sessionId);await roster.refreshBalance(gb.sessionId);await roster.claim(ga.sessionId);
 check(a.calls.length+b.calls.length==before,'status balance and claim never reach exchange');
 final store=NeverStore(),vault=WorkBuddyVault(NeverStore());
 check(!await owners.first.saveVerified(WorkBuddyVault(store),'a'*64,admission:()=>true)&&store.calls==0,'identity flow cannot persist credentials');
 check(!await owners.first.bindSaved(vault,'a'*64,admission:()=>true),'identity flow cannot bind persisted credentials');
 final transport=WorkBuddyIdentityExchange(a);
 for(final path in ['/v2/billing/meter/daily-checkin','/v2/billing/meter/checkin-activity-status','/billing/meter/get-user-resource-summary','/v2/plugin/auth/refresh']){
  var blocked=false;try{await transport.send(WorkBuddyRequest(Uri.https('www.workbuddy.cn',path),'POST',{}),()=>true);}on WorkBuddyApiFailure catch(e){blocked=!e.mayHaveBeenSent;}check(blocked,'transport refuses $path');
 }
 var wrong=false;try{await transport.send(WorkBuddyRequest(Uri.https('www.workbuddy.cn','/v2/plugin/account'),'POST',{}),()=>true);}on WorkBuddyApiFailure catch(e){wrong=!e.mayHaveBeenSent;}check(wrong,'profile wrong HTTP method refused');
 roster.close();check(roster.accounts.isEmpty&&owners.every((f)=>f.uid==null&&f.domain==null&&!f.loginPending),'close clears all exposed identities and pending sessions');
 await owners.first.poll();check(a.calls.length+b.calls.length==before,'closed owners cannot poll again');
 final pending=Fake('late')..waitToken=Completer<void>();final lateOwner=WorkBuddyAccountFlow.inMemory(exchange:pending,identityValidationOnly:true,now:()=>DateTime.utc(2026,11,5));
 await lateOwner.begin();final waiting=lateOwner.poll();await Future<void>.delayed(Duration.zero);lateOwner.close();pending.waitToken!.complete();await waiting;
 check(lateOwner.uid==null&&pending.calls.length==2,'close during token wait never dispatches profile');
 await HttpOverrides.runZoned(()async{
  final real=WorkBuddyAccountFlow.inMemory(identityValidationOnly:true);
  check(clients==0,'constructing enabled identity owner allocates no HTTP client');
  real.close();check(await real.begin()==null&&clients==0,'closed real identity owner cannot start authorization');
  var denied=false;try{await WorkBuddyHttps.identityValidation().send(WorkBuddyRequest(Uri.https('www.workbuddy.cn','/v2/billing/meter/daily-checkin'),'POST',{}),()=>true);}on WorkBuddyApiFailure catch(e){denied=!e.mayHaveBeenSent;}
  check(denied&&clients==0,'real identity transport rejects check-in before creating an HTTP client');
 },createHttpClient:(_){clients++;throw StateError('network forbidden');});
 print('RESULT $checks identity checks');
}
