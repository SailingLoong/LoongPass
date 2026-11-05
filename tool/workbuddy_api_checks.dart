import '../lib/workbuddy_api.dart';
void check(bool v) {if(!v) throw StateError('check');}
Future<void> rejected(Future<Object?> Function() f) async {try{await f();}on WorkBuddyApiFailure{return;}throw StateError('expected failure');}
class Fake implements WorkBuddyExchange {
  final requests=<WorkBuddyRequest>[];
  void Function(WorkBuddyRequest)? onSend;
  WorkBuddyApiFailure? failure;
  final replies=<Map<String,Object?>>[];
  Future<Map<String,Object?>> send(WorkBuddyRequest r,bool Function() admitted) async {if(!admitted())throw const WorkBuddyApiFailure('Expired');requests.add(r);onSend?.call(r);if(failure!=null)throw failure!;if(replies.isEmpty)throw const WorkBuddyApiFailure('Unknown');return replies.removeAt(0);}
}
Map<String,Object?> ready()=>{'code':0,'data':{'state':'synthetic-state','authUrl':'https://www.codebuddy.cn/login?state=synthetic-state'}};
Map<String,Object?> token()=>{'code':0,'data':{'accessToken':'synthetic-token','domain':'www.workbuddy.cn'}};
Map<String,Object?> profile()=>{'code':0,'data':{'uid':'synthetic-user','type':'personal','domain':'www.workbuddy.cn'}};
Future<void> main() async {
 int passed=0,failed=0;
 Future<void> test(String n,Future<void> Function() f)async{try{await f();passed++;print('PASS $n');}catch(_){failed++;print('FAIL $n');}}
 await test('authorization endpoints and verified identity',()async{
  final f=Fake()..replies.addAll([ready(),token(),profile()]);final api=WorkBuddyApi(f,isCurrent:()=>true);
  final url=await api.begin();check(url.host=='www.workbuddy.cn');final a=await api.poll();check(a!.uid=='synthetic-user');check(a.domain=='www.workbuddy.cn');
  check(f.requests[0].uri.path=='/v2/plugin/auth/state');check(f.requests[0].uri.queryParameters['platform']=='workbuddy');check(f.requests[1].method=='GET');check(!f.requests[2].headers.containsKey('X-User-Id'));check(!a.toString().contains('synthetic-token'));
 });
 await test('pending authorization remains pending',()async{final f=Fake()..replies.addAll([ready(),{'code':11217}]);final api=WorkBuddyApi(f,isCurrent:()=>true);await api.begin();check(await api.poll()==null);});
 await test('cancel prevents poll',()async{final f=Fake()..replies.add(ready());final api=WorkBuddyApi(f,isCurrent:()=>true);await api.begin();api.cancel();await rejected(()=>api.poll());check(f.requests.length==1);});
 await test('foreign verification URL rejected',()async{final f=Fake()..replies.add({'code':0,'data':{'state':'x','url':'https://evil.example/?state=x'}});await rejected(()=>WorkBuddyApi(f,isCurrent:()=>true).begin());});
 await test('enterprise authorization refused',()async{final t=token();(t['data'] as Map)['enterpriseId']='org';final f=Fake()..replies.addAll([ready(),t]);final api=WorkBuddyApi(f,isCurrent:()=>true);await api.begin();await rejected(()=>api.poll());});
 await test('profile domain mismatch refused',()async{final p=profile();(p['data'] as Map)['domain']='www.codebuddy.cn';final f=Fake()..replies.addAll([ready(),token(),p]);final api=WorkBuddyApi(f,isCurrent:()=>true);await api.begin();await rejected(()=>api.poll());});
 await test('status and claim use real paths without client spoof',()async{final f=Fake()..replies.addAll([{'code':0},{'code':0}]);final api=WorkBuddyApi(f,isCurrent:()=>true);final a=WorkBuddyAccount('www.workbuddy.cn','synthetic-user','synthetic-token');await api.status(a);await api.claimOnce(a);check(f.requests[0].uri.path.endsWith('checkin-activity-status'));check(f.requests[1].uri.path.endsWith('daily-checkin'));check(f.requests.every((r)=>!r.headers.containsKey('Origin')&&!r.headers.containsKey('X-Client-Platform')));});
 await test('claim failure never retries',()async{final f=Fake();final api=WorkBuddyApi(f,isCurrent:()=>true);await rejected(()=>api.claimOnce(WorkBuddyAccount('www.workbuddy.cn','u','synthetic-token')));check(f.requests.length==1);});
 await test('revoked owner never sends',()async{final f=Fake();final api=WorkBuddyApi(f,isCurrent:()=>false);await rejected(()=>api.begin());check(f.requests.isEmpty);});
 await test('unsafe credential rejected without leaking it',()async{await rejected(()async=>WorkBuddyAccount('www.workbuddy.cn','u','synthetic\r\ntoken'));});
 await test('cancel during token await blocks profile',()async{
  final f=Fake()..replies.addAll([ready(),token(),profile()]);final api=WorkBuddyApi(f,isCurrent:()=>true);await api.begin();
  f.onSend=(r){if(r.uri.path.endsWith('/auth/token'))api.cancel();};await rejected(()=>api.poll());check(f.requests.length==2);
 });
 await test('flow expiration prevents further request',()async{
  var now=DateTime.utc(2026,11,4);final f=Fake()..replies.add(ready());final api=WorkBuddyApi(f,isCurrent:()=>true,now:()=>now);await api.begin();now=now.add(const Duration(minutes:11));await rejected(()=>api.poll());check(f.requests.length==1);
 });
 await test('duplicate state rejected',()async{
  final f=Fake()..replies.add({'code':0,'data':{'state':'s','url':'https://www.codebuddy.cn/login?state=s&state=s'}});await rejected(()=>WorkBuddyApi(f,isCurrent:()=>true).begin());
 });
 await test('owner revoked after claim dispatch stays outcome unknown',()async{
  var current=true;final f=Fake()..replies.add({'code':0});f.onSend=(_){current=false;};
  final api=WorkBuddyApi(f,isCurrent:()=>current);
  try{await api.claimOnce(WorkBuddyAccount('www.workbuddy.cn','u','synthetic-token'));throw StateError('expected failure');}
  on WorkBuddyApiFailure catch(e){check(e.code=='OutcomeUnknown');}check(f.requests.length==1);
 });
 await test('cancel during claim dispatch stays outcome unknown',()async{
  final f=Fake()..replies.add({'code':0});final api=WorkBuddyApi(f,isCurrent:()=>true);f.onSend=(_){api.cancel();};
  try{await api.claimOnce(WorkBuddyAccount('www.workbuddy.cn','u','synthetic-token'));throw StateError('expected failure');}
  on WorkBuddyApiFailure catch(e){check(e.code=='OutcomeUnknown');}check(f.requests.length==1);
 });
 await test('before-dispatch refusal is explicitly unsent',()async{
  final f=Fake();final api=WorkBuddyApi(f,isCurrent:()=>false);
  try{await api.claimOnce(WorkBuddyAccount('www.workbuddy.cn','u','synthetic-token'));throw StateError('expected failure');}
  on WorkBuddyApiFailure catch(e){check(e.code=='ExpiredAuthorization'&&!e.mayHaveBeenSent);}check(f.requests.isEmpty);
 });
 await test('transport proven unsent refusal remains explicit',()async{
  final f=Fake()..failure=const WorkBuddyApiFailure('ExpiredAuthorization',mayHaveBeenSent:false);final api=WorkBuddyApi(f,isCurrent:()=>true);
  try{await api.claimOnce(WorkBuddyAccount('www.workbuddy.cn','u','synthetic-token'));throw StateError('expected failure');}
  on WorkBuddyApiFailure catch(e){check(e.code=='ExpiredAuthorization'&&!e.mayHaveBeenSent);}check(f.requests.length==1);
 });
 await test('transport ambiguous cancellation cannot imply unsent',()async{
  final f=Fake()..failure=const WorkBuddyApiFailure('ExpiredAuthorization');final api=WorkBuddyApi(f,isCurrent:()=>true);
  try{await api.claimOnce(WorkBuddyAccount('www.workbuddy.cn','u','synthetic-token'));throw StateError('expected failure');}
  on WorkBuddyApiFailure catch(e){check(e.code=='OutcomeUnknown'&&e.mayHaveBeenSent);}check(f.requests.length==1);
 });
 print('$passed passed; $failed failed');if(failed>0)throw StateError('suite failed');
}
