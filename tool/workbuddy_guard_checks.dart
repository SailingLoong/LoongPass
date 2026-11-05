import 'dart:io';
import '../lib/workbuddy_api.dart';
import '../lib/workbuddy_account_flow.dart';

Future<void> main()async{
 var checks=0,clients=0;
 void check(bool ok,String name){if(!ok)throw StateError(name);checks++;print('PASS $name');}
 final account=WorkBuddyAccount('www.workbuddy.cn','synthetic-user','synthetic-token');
 await HttpOverrides.runZoned(()async{
  final owner=WorkBuddyAccountFlow.inMemory();
  check(clients==0,'constructing a real owner performs no network operation');
  owner.close();check(await owner.begin()==null&&clients==0,'closed owner cannot authorize');
  final api=WorkBuddyApi(WorkBuddyHttps(),isCurrent:()=>false);
  for(final operation in [()=>api.begin(),()=>api.status(account),()=>api.claimOnce(account)]){
   var denied=false;
   try{await operation();}on WorkBuddyApiFailure catch(e){denied=e.code=='ExpiredAuthorization'&&!e.mayHaveBeenSent;}
   check(denied&&clients==0,'retired authorization stops before HTTP allocation');
  }
  var denied=false;
  try{await WorkBuddyHttps.identityValidation().send(WorkBuddyRequest(
   Uri.https('www.workbuddy.cn','/v2/billing/meter/daily-checkin'),'POST',{}),()=>true);}
  on WorkBuddyApiFailure catch(e){denied=!e.mayHaveBeenSent;}
  check(denied&&clients==0,'identity-only transport cannot dispatch check-in');
 },createHttpClient:(_){clients++;throw StateError('network forbidden in offline check');});
 print('RESULT $checks guard checks; no real network');
}
