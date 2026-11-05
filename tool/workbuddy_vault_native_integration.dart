// Dedicated synthetic Keychain only. JSON IPC invokes native FlutterMethodCall
// handlers; this is not a Flutter engine/UI or live-server acceptance test.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../lib/workbuddy_vault.dart';
import '../lib/workbuddy_accounts.dart';
import '../lib/workbuddy_account_flow.dart';
import '../lib/workbuddy_api.dart';
class NativeStore implements WorkBuddyVaultStore {
 final Process child;final StreamIterator<String> lines;
 NativeStore(this.child):lines=StreamIterator(child.stdout.transform(utf8.decoder).transform(const LineSplitter()));
 Future<Object?> invoke(String method,Map<String,Object?> args)async{
  child.stdin.writeln(jsonEncode({'method':method,'args':args}));await child.stdin.flush();
  if(!await lines.moveNext())throw StateError('Native fixture closed');
  final row=jsonDecode(lines.current) as Map;if(row.containsKey('error'))throw StateError('Native vault failed');return row['value'];
 }
 @override Future<Map<String,Object?>?> read(String key)async{final v=await invoke('readWorkBuddyVault',{'key':key});return v==null?null:Map<String,Object?>.from(v as Map);}
 @override Future<bool> compareExchange(String key,int? expected,Map<String,Object?> value)async=>await invoke('compareExchangeWorkBuddyVault',{'key':key,'expected':expected,'value':value}) as bool;
}
class LoginExchange implements WorkBuddyExchange {
 final String uid;LoginExchange(this.uid);
 Future<Map<String,Object?>> send(WorkBuddyRequest r,bool Function() admitted)async{
  if(!admitted())throw const WorkBuddyApiFailure('ExpiredAuthorization');
  if(r.uri.path.endsWith('/auth/state'))return {'code':0,'data':{'state':'state-$uid','authUrl':'https://www.workbuddy.cn/login?state=state-$uid'}};
  if(r.uri.path.endsWith('/auth/token'))return {'code':0,'data':{'accessToken':'synthetic-$uid','domain':'www.workbuddy.cn','expiresIn':3600}};
  if(r.uri.path=='/v2/plugin/account')return {'code':0,'data':{'uid':r.headers['Authorization']!.substring('Bearer synthetic-'.length),'type':'personal','domain':'www.workbuddy.cn'}};
  throw StateError('No claim or other request permitted');
 }
}
Future<void> main(List<String> args)async{
 final root=await Directory(args[1]).createTemp('end-to-end-');final child=await Process.start(args[0],[],environment:{'LOONGPASS_TEST_ROOT':root.path});
 final store=NativeStore(child);final vault=WorkBuddyVault(store,now:()=>DateTime.utc(2026,11,5));int checks=0;
 void check(bool b,String name){if(!b)throw StateError(name);checks++;print('PASS $name');}
 WorkBuddyVaultCredential c(String uid)=>WorkBuddyVaultCredential(domain:'www.workbuddy.cn',endpoint:'www.workbuddy.cn',uid:uid,accessToken:'synthetic-access-$uid',refreshToken:'synthetic-refresh-$uid',expiresAt:DateTime.utc(2026,11,6));
 final a='a'*64,b='b'*64;
 try{
  check(await vault.save(a,c('A')),'Dart saves A through native handler to Keychain');
  check(await vault.save(b,c('B')),'Dart saves independent B through native handler');
  final lease=await vault.restore(a,verify:(c,admitted)async=>admitted()&&c.uid=='A'&&c.accessToken=='synthetic-access-A');
  check(lease!=null&&await lease.checkCurrent(),'Keychain credential restores through injected identity verifier');
  check(!lease!.automaticEnabled,'restored session automatic remains off');
  await vault.revoke(a);check(!lease.current,'local revoke retires memory lease');
  final restart=WorkBuddyVault(store,now:()=>DateTime.utc(2026,11,5));
  check(await restart.restore(a,verify:(c,admitted)async=>true)==null,'new coordinator cannot restore revoked A');
  check((await store.read(a))!.length==3,'native tombstone contains no credentials');
  check(await restart.restore(b,verify:(c,admitted)async=>admitted()&&c.uid=='B')!=null,'B unaffected by A revoke');
  check(await vault.beginRotation(b)!=null,'native CAS stores rotation marker before refresh');
  check(await restart.restore(b,verify:(c,admitted)async=>true)==null,'new coordinator disables unknown rotation');
  check(await vault.beginRotation(b)==null,'unknown rotation cannot repeat');
  final queue=['C','D'];
  final added=WorkBuddyAccounts(create:()=>WorkBuddyAccountFlow.inMemory(exchange:LoginExchange(queue.removeAt(0)),now:()=>DateTime.utc(2026,11,5)));
  final grantC=(await added.beginAuthorization())!;check(await added.pollAndSave(grantC.sessionId,vault)!=null,'existing login C saves to actual synthetic Keychain before roster admission');
  final grantD=(await added.beginAuthorization())!;check(await added.pollAndSave(grantD.sessionId,vault)!=null,'second existing login D uses separate Keychain account');
  check(added.accounts.length==2,'both verified saved login identities in roster');added.close();
  final recovered=WorkBuddyAccounts(create:()=>WorkBuddyAccountFlow.inMemory(exchange:LoginExchange('unused'),now:()=>DateTime.utc(2026,11,5)));
  final restartVault=WorkBuddyVault(store,now:()=>DateTime.utc(2026,11,5));
  final restoredC=await recovered.restore(restartVault,WorkBuddyVault.accountKey('www.workbuddy.cn','C'));
  final restoredD=await recovered.restore(restartVault,WorkBuddyVault.accountKey('www.workbuddy.cn','D'));
  check(restoredC!=null&&restoredD!=null,'new roster verifies and restores both saved login identities from Keychain');
  await recovered.revokeStored(restoredC!);check(recovered.accounts.single.uid=='D','roster local revocation preserves other saved account');
  check((await store.read(WorkBuddyVault.accountKey('www.workbuddy.cn','C')))!['state']=='revoked','roster revocation reaches actual synthetic Keychain tombstone');recovered.close();
 }finally{
  vault.close();await child.stdin.close();final exitCode=await child.exitCode.timeout(const Duration(seconds:10));await store.lines.cancel();await child.stderr.drain<void>();
  check(exitCode==0,'native server exits and deletes dedicated Keychain');
  check(!await File('${root.path}/synthetic.keychain-db').exists(),'synthetic Keychain file removed');
  // Keychain daemon may leave a regenerable lock sidecar; keep fixture evidence.
 }
 print('RESULT $checks native integration checks');
}
