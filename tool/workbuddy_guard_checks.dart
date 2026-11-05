import 'dart:async';
import 'dart:io';
import '../lib/workbuddy_api.dart';
import '../lib/workbuddy_account_flow.dart';
import '../lib/native_account_gate.dart';
class Fake implements WorkBuddyExchange {
 int calls=0;
 Future<Map<String,Object?>> send(WorkBuddyRequest r,bool Function() admitted)async{
  if(!admitted())throw StateError('retired synthetic owner');calls++;
  if(r.uri.path.endsWith('/auth/state'))return {'code':0,'data':{'state':'SYNTHETIC','url':'https://www.codebuddy.cn/authorize?state=SYNTHETIC'}};
  return {'code':0};
 }
}
Future<void> main()async{
 int pass=0,fail=0,clients=0;
 Future<void> check(String name,FutureOr<void> Function() body)async{try{await body();pass++;print('PASS $name');}catch(e){fail++;print('FAIL $name: ${e.runtimeType}');}}
 void expect(bool value){if(!value)throw StateError('assertion');}
 Future<void> unavailable(FutureOr<Object?> Function() action)async{
  try{final result=await action();if(result is WorkBuddyAccountFlow)result.close();}on WorkBuddyApiFailure catch(e){expect(e.code=='WorkBuddyUnavailable'&&!e.mayHaveBeenSent);return;}throw StateError('not blocked');
 }
 await HttpOverrides.runZoned(()async{
  await check('other platforms enabled cannot enable WorkBuddy',(){expect(nativeAccountAdaptersValidated&&!workBuddyNativeAdapterValidated);});
  await check('default memory factory fails closed',()=>unavailable(()=>WorkBuddyAccountFlow.inMemory()));
  await check('explicit real transport factory fails closed',()=>unavailable(()=>WorkBuddyAccountFlow(exchange:WorkBuddyHttps(),ownerGeneration:'SYNTHETIC',isOwnerCurrent:()=>true)));
  final request=WorkBuddyRequest(Uri.parse('https://www.codebuddy.cn/v2/plugin/auth/state'),'POST',const {});
  await check('direct HTTPS send blocked before HttpClient creation',()=>unavailable(()=>WorkBuddyHttps().send(request,()=>true)));
  await check('authorization API cannot bypass production transport guard',()=>unavailable(()=>WorkBuddyApi(WorkBuddyHttps(),isCurrent:()=>true).begin()));
  final account=WorkBuddyAccount('www.workbuddy.cn','SYNTHETIC-UID','SYNTHETIC-TOKEN');
  await check('status API cannot bypass production guard',()=>unavailable(()=>WorkBuddyApi(WorkBuddyHttps(),isCurrent:()=>true).status(account)));
  await check('claim API blocked with definitely-unsent classification',()=>unavailable(()=>WorkBuddyApi(WorkBuddyHttps(),isCurrent:()=>true).claimOnce(account)));
  await check('closed production paths allocate no HttpClient',(){expect(clients==0);});
  await check('explicit fake owner injection still works',()async{final fake=Fake();final flow=WorkBuddyAccountFlow.inMemory(exchange:fake);try{expect(await flow.begin()!=null);expect(fake.calls==1);}finally{flow.close();}});
  await check('explicit fake API injection still works',()async{final fake=Fake();await WorkBuddyApi(fake,isCurrent:()=>true).status(account);expect(fake.calls==1&&clients==0);});
 },createHttpClient:(_){clients++;throw StateError('real network forbidden in this probe');});
 print('$pass passed; $fail failed');if(fail>0)throw StateError('guard checks failed');
}
