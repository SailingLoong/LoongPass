import 'dart:io';
import '../lib/workbuddy_api.dart';
import '../lib/workbuddy_account_flow.dart';
import '../lib/native_account_gate.dart';
Future<void> main()async{
 int checks=0,clients=0;void check(bool ok,String name){if(!ok)throw StateError(name);checks++;print('PASS $name');}
 await HttpOverrides.runZoned(()async{
  check(workBuddyMemoryIdentityApproved&&!workBuddyNativeAdapterValidated&&!workBuddyPersistentAccessValidated,'only memory identity capability prepared');
  final flow=WorkBuddyAccountFlow.inMemory(identityValidationOnly:true);
  check(flow.uid==null&&!flow.canClaim&&!flow.claimOwnerAvailable&&clients==0,'constructing ready owner performs no request or storage');
  await flow.refreshStatus();await flow.refreshBalance();await flow.claim();
  check(clients==0,'forbidden flow operations allocate no HTTP client');flow.close();
  for(final path in ['/v2/billing/meter/daily-checkin','/v2/billing/meter/checkin-activity-status','/billing/meter/get-user-resource-summary','/v2/plugin/auth/refresh']){
   var blocked=false;try{await WorkBuddyHttps.identityValidation().send(WorkBuddyRequest(Uri.https('www.workbuddy.cn',path),'POST',{}),()=>true);}on WorkBuddyApiFailure catch(e){blocked=!e.mayHaveBeenSent;}
   check(blocked&&clients==0,'ready actual transport refuses $path before HTTP');
  }
  var blocked=false;try{await WorkBuddyHttps().send(WorkBuddyRequest(Uri.https('www.workbuddy.cn','/v2/plugin/auth/state'),'POST',{}),()=>true);}on WorkBuddyApiFailure catch(e){blocked=e.code=='WorkBuddyUnavailable'&&!e.mayHaveBeenSent;}
  check(blocked&&clients==0,'original broad WorkBuddy production transport stays closed');
 },createHttpClient:(_){clients++;throw StateError('all actual network forbidden in this offline check');});
 check(clients==0,'zero clients and zero actual network requests');print('RESULT $checks prepared checks');
}
