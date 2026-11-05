import '../lib/workbuddy_api.dart';
class Fake implements WorkBuddyExchange {
 final requests=<WorkBuddyRequest>[]; final List<Map<String,Object?>> replies;
 Fake(this.replies);
 Future<Map<String,Object?>> send(WorkBuddyRequest r,bool Function() admitted)async{if(!admitted())throw StateError('gate');requests.add(r);return replies.removeAt(0);}
}
Map<String,Object?> state()=>{'code':0,'data':{'state':'s','authUrl':'https://www.codebuddy.cn/login?state=s&version=5.9.3&loginSessionId=synthetic'}};
Map<String,Object?> token([Map<String,Object?> extra=const {}])=>{'code':0,'data':{'accessToken':'synthetic-secret','domain':'www.codebuddy.cn',...extra}};
Map<String,Object?> profile([Object? type='personal'])=>{'code':0,'data':{'uid':'synthetic','type':type}};
void check(bool b){if(!b)throw StateError('assertion');}
Future<void> reject(Future<Object?> Function() f)async{try{await f();}on WorkBuddyApiFailure{return;}throw StateError('accepted');}
Future<void> main()async{
 int pass=0,fail=0;
 Future<void> test(String n,Future<void> Function() f)async{try{await f();pass++;print('PASS $n');}catch(_){fail++;print('FAIL $n');}}
 await test('endpoint distinct from domain and account-scoped headers',()async{
 final f=Fake([state(),token(),profile()]);final a=WorkBuddyApi(f,isCurrent:()=>true);final url=await a.begin();await a.poll();
 check(url.host=='www.workbuddy.cn'&&url.queryParameters['loginSessionId']=='synthetic');
 check(f.requests.every((r)=>r.uri.host=='www.workbuddy.cn'));
 for(final r in f.requests.take(2)){for(final h in ['X-No-Authorization','X-No-User-Id','X-No-Enterprise-Id','X-No-Department-Info']){check(r.headers[h]=='true');}check(!r.headers.containsKey('Authorization'));}
 check(f.requests[0].headers['X-Domain']=='www.workbuddy.cn');check(!f.requests[1].headers.containsKey('X-Domain'));
 final p=f.requests.last;check(p.uri.path=='/v2/plugin/account'&&!p.uri.hasQuery&&p.method=='GET');check(p.headers['X-Domain']=='www.codebuddy.cn'&&p.headers['Authorization']=='Bearer synthetic-secret'&&!p.headers.containsKey('X-User-Id'));
 });
 await test('five minute deadline blocks dispatch',()async{var now=DateTime.utc(2026);final f=Fake([state(),token(),profile()]);final a=WorkBuddyApi(f,isCurrent:()=>true,now:()=>now);await a.begin();now=now.add(const Duration(minutes:5));await reject(()=>a.poll());check(f.requests.length==1);});
 await test('pro is known personal edition',()async{final f=Fake([state(),token(),profile('pro')]);final a=WorkBuddyApi(f,isCurrent:()=>true);await a.begin();check((await a.poll())!=null);});
 await test('unknown identity fails closed',()async{for(final type in [null,'individual','future','ultimate','exclusive',7]){final f=Fake([state(),token(),profile(type)]);final a=WorkBuddyApi(f,isCurrent:()=>true);await a.begin();await reject(()=>a.poll());}});
 await test('missing token domain uses endpoint',()async{final t=token();(t['data'] as Map).remove('domain');final f=Fake([state(),t,profile()]);final a=WorkBuddyApi(f,isCurrent:()=>true);await a.begin();check((await a.poll())!.domain=='www.workbuddy.cn');});
 await test('profile pending retains flow',()async{final f=Fake([state(),token(),{'code':12151},profile()]);final a=WorkBuddyApi(f,isCurrent:()=>true);await a.begin();check(await a.poll()==null);check(await a.poll()!=null);});
 await test('unknown token payload fails closed',()async{final f=Fake([state(),{'code':0,'data':{'access_token':'synthetic-secret'}}]);final a=WorkBuddyApi(f,isCurrent:()=>true);await a.begin();await reject(()=>a.poll());});
 await test('expired or malformed expiry fails closed',()async{for(final extra in <Map<String,Object?>>[{'expiresAt':1},{'expiresIn':-1},{'expiresAt':'tomorrow'},{'expiresIn':8640000000000}]){final f=Fake([state(),token(extra),profile()]);final a=WorkBuddyApi(f,isCurrent:()=>true);await a.begin();await reject(()=>a.poll());}});
 await test('usable token precedes pending envelope',()async{final t=token();t['code']=11217;final f=Fake([state(),t,profile()]);final a=WorkBuddyApi(f,isCurrent:()=>true);await a.begin();check(await a.poll()!=null);});
 await test('token pending sends no profile',()async{final f=Fake([state(),{'code':11217}]);final a=WorkBuddyApi(f,isCurrent:()=>true);await a.begin();check(await a.poll()==null&&f.requests.length==2);});
 await test('known personal before five minute boundary',()async{var now=DateTime.utc(2026);final f=Fake([state(),token({'expiresIn':60}),profile(' PERSONAL ')]);final a=WorkBuddyApi(f,isCurrent:()=>true,now:()=>now);await a.begin();now=now.add(const Duration(minutes:4,seconds:59));check(await a.poll()!=null);});
 await test('enterprise and invalid domain remain refused',()async{for(final extra in <Map<String,Object?>>[{'enterpriseId':'org'},{'domain':'evil.example'},{'domain':7}]){final f=Fake([state(),token(extra),profile()]);final a=WorkBuddyApi(f,isCurrent:()=>true);await a.begin();await reject(()=>a.poll());}});
 await test('known token expiry blocks requests after authorization',()async{var now=DateTime.utc(2026);final f=Fake([state(),token({'expiresIn':1}),profile(),{'code':0}]);final a=WorkBuddyApi(f,isCurrent:()=>true,now:()=>now);await a.begin();final account=(await a.poll())!;now=now.add(const Duration(seconds:1));await reject(()=>a.status(account));await reject(()=>a.claimOnce(account));check(f.requests.length==3);});
 print('$pass passed; $fail failed');if(fail>0)throw StateError('suite failed');
}
