// New single-account chain only; fake authorization/server and fake credential
// storage. No real credentials, native default Keychain or network.
import '../lib/workbuddy_api.dart';
import '../lib/workbuddy_vault.dart';
import '../lib/workbuddy_accounts.dart';
import '../lib/workbuddy_account_flow.dart';
import 'workbuddy_multi_checks.dart' as old;
class VaultStore implements WorkBuddyVaultStore {
 final rows=<String,Map<String,Object?>>{};
 Future<Map<String,Object?>?> read(String key)async=>rows[key]==null?null:Map.of(rows[key]!);
 Future<bool> compareExchange(String key,int? expected,Map<String,Object?> value)async{if(rows[key]?['revision']!=expected)return false;rows[key]=Map.of(value);return true;}
}
class Server extends old.Server {
 bool expire=false;
 Server(super.uid);
 @override Future<Map<String,Object?>> send(WorkBuddyRequest r,bool Function() admitted)async{
  if(expire&&r.uri.path.endsWith('/auth/token'))throw const WorkBuddyApiFailure('ExpiredAuthorization',mayHaveBeenSent:false);
  final response=await super.send(r,admitted);
  if(r.uri.path.endsWith('/auth/token')&&response['data'] is Map)return {...response,'data':{...Map<String,Object?>.from(response['data'] as Map),'expiresIn':3600}};
  return response;
 }
}
Future<void> main()async{
 int checks=0;void check(bool ok,String name){if(!ok)throw StateError(name);checks++;print('PASS $name');}
 final preciseNow=DateTime(2026,11,5,12,0,0,0,123);
 final preciseStore=VaultStore();
 final preciseVault=WorkBuddyVault(preciseStore,now:()=>preciseNow);
 final preciseServer=Server('precise-expiry');
 final preciseAccounts=WorkBuddyAccounts(create:()=>WorkBuddyAccountFlow.inMemory(
  exchange:preciseServer,store:old.Memory(),now:()=>preciseNow));
 final preciseGrant=(await preciseAccounts.beginAuthorization())!;
 check(await preciseAccounts.pollAndSave(preciseGrant.sessionId,preciseVault)!=null,
  'real-clock local timezone and microseconds survive save and lease binding');
 preciseAccounts.close();preciseVault.close();
 final server=Server('single'),rig=old.Rig()..queue.add(server);final store=VaultStore();final vault=WorkBuddyVault(store,now:()=>DateTime.utc(2026,11,5,4));
 final first=rig.roster();final grant=(await first.beginAuthorization())!;
 check(await first.pollAndSave(grant.sessionId,vault)!=null&&store.rows.length==1,'existing official flow saves one verified identity before admission');
 first.close();rig.queue.add(server);final restarted=rig.roster();
 final id=await restarted.restoreSingle(vault,()async=>store.rows.keys.toList());
 check(id!=null&&restarted.accounts.single.uid=='single','single saved identity restores into existing journal owner');
 check(server.posts==0,'restore performs no check-in');
 await restarted.claim(id!);
 check(server.posts==1&&restarted.selected!.result?.credited==20,'restored single owner uses existing claim core and verifies synthetic credit');
 await restarted.claim(id);check(server.posts==1,'same restored owner cannot repeat claim');restarted.close();
 rig.queue.add(server);final third=rig.roster();final again=await third.restoreSingle(vault,()async=>store.rows.keys.toList());await third.claim(again!);
 check(server.posts==1,'next restore preserves journal and cannot replay settled check-in');third.close();
 var listCalls=0;check(await third.restoreSingle(vault,()async{listCalls++;return store.rows.keys.toList();})==null&&listCalls==0,'closed controller does not inspect saved credentials');
 final many=rig.roster();check(await many.restoreSingle(vault,()async=>['a'*64,'b'*64])==null,'single chain refuses ambiguous saved accounts before token reads');many.close();
 final expired=Server('expired')..expire=true;rig.queue.add(expired);final failed=rig.roster();final bad=(await failed.beginAuthorization())!;await failed.pollAndSave(bad.sessionId,vault);
 check(failed.sessions.isEmpty,'failed persisted authorization retires stale slot so single add is not permanently blocked');failed.close();
 rig.queue.add(server);final renewed=rig.roster();final renewGrant=(await renewed.beginAuthorization())!;
 check(await renewed.pollAndSave(renewGrant.sessionId,vault,savedKeys:()async=>store.rows.keys.toList())!=null&&store.rows.values.single['revision']==2,'fresh official reauthorization updates the same saved identity without extra records');
 await renewed.claim(renewGrant.sessionId);check(server.posts==1,'reauthorization preserves settled claim journal');renewed.close();
 final other=Server('other');rig.queue.add(other);final rejected=rig.roster();final otherGrant=(await rejected.beginAuthorization())!;
 check(await rejected.pollAndSave(otherGrant.sessionId,vault,savedKeys:()async=>store.rows.keys.toList())==null&&store.rows.length==1,'single saved identity cannot grow a hidden second account after memory removal');rejected.close();
 print('RESULT $checks single-chain checks');
}
