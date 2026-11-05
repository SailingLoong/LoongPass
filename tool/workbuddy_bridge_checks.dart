import '../lib/workbuddy_api.dart';
import '../lib/workbuddy_claim.dart';
void check(bool value){if(!value)throw StateError('check');}
class Store implements WorkBuddyAttemptStore {
 WorkBuddyAttempt? row;
 Future<WorkBuddyAttempt?> read(String key)async=>row;
 Future<bool> compareAndSet(String key,int? revision,WorkBuddyAttempt next)async{if(row?.revision!=revision)return false;row=next;return true;}
}
class Exchange implements WorkBuddyExchange {
 int posts=0,statusReads=0; bool loseReceipt=false; void Function()? afterClaim;
 Future<Map<String,Object?>> send(WorkBuddyRequest r,bool Function() admitted)async{
  check(admitted());
  if(r.uri.path.endsWith('daily-checkin')){posts++;afterClaim?.call();if(loseReceipt)throw const WorkBuddyApiFailure('ExpiredAuthorization');return {'code':0,'credit':20};}
  statusReads++;return {'code':0,'data':{'today_checked_in':posts>0,'active':true}};
 }
}
Future<void> main()async{
 int passed=0,failed=0;
 Future<void> test(String name,Future<void> Function() run)async{try{await run();passed++;print('PASS $name');}catch(e){failed++;print('FAIL $name: $e');}}
 final subject=WorkBuddySubject('www.workbuddy.cn','synthetic-user','g1');
 final account=WorkBuddyAccount(subject.domain,subject.uid,'synthetic-token');
 WorkBuddyClaimCore core(Store store,WorkBuddyTransport t,bool Function() current)=>WorkBuddyClaimCore(store,t,()=>DateTime.utc(2026,11,4,3),isCurrent:(_)=>current());
 await test('full owner balance and receipt confirm credit once',()async{
  final f=Exchange(),s=Store();final api=WorkBuddyApi(f,isCurrent:()=>true);
  final t=WorkBuddyApiTransport(api,account,subject,readCompleteBalance:(s)async=>(subject:s,totalRemaining:f.posts>0?30.0:10.0));
  check((await core(s,t,()=>true).claim(subject)).credited==20);check((await core(s,t,()=>true).claim(subject)).state==WorkBuddyState.alreadyClaimed);check(f.posts==1);
 });
 await test('missing complete balance prevents claim and intent',()async{
  final f=Exchange(),s=Store();final t=WorkBuddyApiTransport(WorkBuddyApi(f,isCurrent:()=>true),account,subject,readCompleteBalance:(s)async=>(subject:s,totalRemaining:null));
  check((await core(s,t,()=>true).claim(subject)).state==WorkBuddyState.unconfirmed);check(f.posts==0&&s.row==null);
 });
 await test('unknown receipt preserves intent across core recreation',()async{
  final f=Exchange()..loseReceipt=true;final s=Store();final t=WorkBuddyApiTransport(WorkBuddyApi(f,isCurrent:()=>true),account,subject,readCompleteBalance:(s)async=>(subject:s,totalRemaining:f.posts>0?30.0:10.0));
  check((await core(s,t,()=>true).claim(subject)).state==WorkBuddyState.unconfirmed);final original=s.row;
  check((await core(s,t,()=>true).claim(subject)).state==WorkBuddyState.unconfirmed);check(identical(original,s.row)&&f.posts==1&&s.row!.receipt==WorkBuddyState.unconfirmed);
 });
 await test('foreign balance identity rejected before claim',()async{
  final f=Exchange(),s=Store();final t=WorkBuddyApiTransport(WorkBuddyApi(f,isCurrent:()=>true),account,subject,readCompleteBalance:(s)async=>(subject:WorkBuddySubject(s.domain,s.uid,'g2'),totalRemaining:10.0));
  try{await core(s,t,()=>true).claim(subject);throw StateError('expected refusal');}on WorkBuddyFailure catch(e){check(e.code=='IdentityMismatch');}check(f.posts==0&&s.row==null);
 });
 await test('foreign requested generation rejected without network',()async{
  final f=Exchange();final t=WorkBuddyApiTransport(WorkBuddyApi(f,isCurrent:()=>true),account,subject,readCompleteBalance:(s)async=>(subject:s,totalRemaining:10.0));
  try{await t.claim(WorkBuddySubject(subject.domain,subject.uid,'g2'));throw StateError('expected refusal');}on WorkBuddyFailure catch(e){check(e.code=='IdentityMismatch');}check(f.posts==0&&f.statusReads==0);
 });
 await test('revocation after POST keeps intent and never replays',()async{
  var current=true;final f=Exchange()..afterClaim=(){current=false;};final s=Store();final t=WorkBuddyApiTransport(WorkBuddyApi(f,isCurrent:()=>current),account,subject,readCompleteBalance:(s)async=>(subject:s,totalRemaining:10.0));
  check((await core(s,t,()=>current).claim(subject)).state==WorkBuddyState.unconfirmed);check(s.row!.receipt==WorkBuddyState.unconfirmed);
  current=true;check((await core(s,t,()=>current).claim(subject)).state==WorkBuddyState.unconfirmed);check(f.posts==1);
 });
 await test('cancel while complete balance awaits prevents intent',()async{
  final f=Exchange(),s=Store();final api=WorkBuddyApi(f,isCurrent:()=>true);final t=WorkBuddyApiTransport(api,account,subject,readCompleteBalance:(s)async{api.cancel();return (subject:s,totalRemaining:10.0);});
  try{await core(s,t,()=>true).claim(subject);throw StateError('expected refusal');}on WorkBuddyFailure catch(e){check(e.code=='ExpiredAuthorization');}check(f.posts==0&&s.row==null);
 });
 await test('invalid complete totals fail closed',()async{
  for(final total in [double.nan,double.infinity,-1.0]){
   final f=Exchange(),s=Store();final t=WorkBuddyApiTransport(WorkBuddyApi(f,isCurrent:()=>true),account,subject,readCompleteBalance:(s)async=>(subject:s,totalRemaining:total));
   check((await core(s,t,()=>true).claim(subject)).state==WorkBuddyState.unconfirmed);check(f.posts==0&&s.row==null);
  }
 });
 await test('credential identity cannot be rebound to another subject',()async{
  final f=Exchange();try{WorkBuddyApiTransport(WorkBuddyApi(f,isCurrent:()=>true),account,WorkBuddySubject(subject.domain,'other','g1'),readCompleteBalance:(s)async=>(subject:s,totalRemaining:10.0));throw StateError('expected refusal');}on WorkBuddyFailure catch(e){check(e.code=='IdentityMismatch');}check(f.posts==0&&f.statusReads==0);
 });
 print('$passed passed; $failed failed');if(failed>0)throw StateError('suite failed');
}
