import 'dart:convert';
import 'source_digest.dart';
// Synthetic persistence preparation only. No production factory or default
// Keychain is configured. Restored credentials require fresh identity proof;
// they never restore automatic opt-in or clear the existing claim journal.
abstract interface class WorkBuddyVaultStore {
 Future<Map<String,Object?>?> read(String key);
 Future<bool> compareExchange(String key,int? expected,Map<String,Object?> value);
}
class WorkBuddyVaultCredential {
 final String domain,endpoint,uid,accessToken;
 final String? refreshToken;
 final DateTime expiresAt;
 WorkBuddyVaultCredential({required this.domain,required this.endpoint,required this.uid,required this.accessToken,this.refreshToken,required this.expiresAt});
 Map<String,Object?> _encode()=>{'domain':domain,'endpoint':endpoint,'uid':uid,'accessToken':accessToken,if(refreshToken!=null)'refreshToken':refreshToken,'expiresAt':expiresAt.millisecondsSinceEpoch};
 static WorkBuddyVaultCredential decode(Map<String,Object?> m){
  String field(String name,int max){final v=m[name];if(v is! String||v.isEmpty||v.length>max||RegExp(r'[^\x21-\x7e]').hasMatch(v))throw const FormatException('Invalid vault record');return v;}
  final domain=field('domain',128),endpoint=field('endpoint',128);
  if(!['www.workbuddy.cn','www.codebuddy.cn'].contains(domain)||!['www.workbuddy.cn','www.codebuddy.cn'].contains(endpoint))throw const FormatException('Invalid vault binding');
  final expiry=m['expiresAt'];if(expiry is! int||expiry<=0||expiry>8640000000000000)throw const FormatException('Invalid expiry');
  return WorkBuddyVaultCredential(domain:domain,endpoint:endpoint,uid:field('uid',512),accessToken:field('accessToken',16384),refreshToken:m.containsKey('refreshToken')?field('refreshToken',16384):null,expiresAt:DateTime.fromMillisecondsSinceEpoch(expiry,isUtc:true));
 }
 @override String toString()=>'WorkBuddyVaultCredential(redacted)';
}
class WorkBuddyVaultLease {
 final WorkBuddyVaultCredential credential;
 final bool Function() _current;
 final Future<bool> Function() _check;
 WorkBuddyVaultLease._(this.credential,this._current,this._check);
 Future<bool> checkCurrent()=>_check();
 bool get current=>_current();
 bool get automaticEnabled=>false;
 @override String toString()=>'WorkBuddyVaultLease(redacted)';
}
class WorkBuddyRotationTicket {
 final String _key;final int _revision;final Object _owner;
 WorkBuddyRotationTicket._(this._key,this._revision,this._owner);
}
class WorkBuddyVault {
 final WorkBuddyVaultStore store;final DateTime Function() now;
 bool _closed=false;
 final _epochs=<String,int>{};final _blocked=<String>{};final Object _owner=Object();
 WorkBuddyVault(this.store,{DateTime Function()? now}):now=now??DateTime.now;
 void _key(String key){if(!RegExp(r'^[a-f0-9]{64}$').hasMatch(key))throw const FormatException('Invalid vault key');}
 int _retire(String key){_key(key);return _epochs[key]=(_epochs[key]??0)+1;}
 bool _current(String key,int epoch)=>!_closed&&_epochs[key]==epoch&&!_blocked.contains(key);
 Map<String,Object?> _record(int revision,String state,[WorkBuddyVaultCredential? c])=>{'schema':1,'revision':revision,'state':state,if(c!=null)...c._encode()};
 void _validate(Map<String,Object?> row){
  if(row['schema']!=1||row['revision'] is! int||(row['revision'] as int)<=0||!['active','rotationPending','revoked'].contains(row['state']))throw const FormatException('Invalid vault state');
  final allowed={'schema','revision','state','domain','endpoint','uid','accessToken','refreshToken','expiresAt'};
  if(row.keys.any((k)=>!allowed.contains(k)))throw const FormatException('Unknown vault field');
  if(row['state']=='revoked'){if(row.keys.any((k)=>!{'schema','revision','state'}.contains(k)))throw const FormatException('Invalid tombstone');}
  else{WorkBuddyVaultCredential.decode(row);}
 }
 static String accountKey(String domain,String uid)=>sourceSha256(utf8.encode(jsonEncode(['workbuddy-v1',domain,uid]))).map((v)=>v.toRadixString(16).padLeft(2,'0')).join();
 Future<bool> save(String key,WorkBuddyVaultCredential credential,{bool Function()? admission,bool replaceVerified=false})async{
  final epoch=_retire(key);bool admitted(){try{return _current(key,epoch)&&(admission?.call()??true);}catch(_){return false;}}if(!admitted())return false;WorkBuddyVaultCredential.decode(credential._encode());
  // Ordinary saves never overwrite. Fresh verified reauthorization may replace
  // the same active identity; unresolved rotation and revocation remain closed.
  final previous=await store.read(key);if(!admitted())return false;
  int? expectedRevision;
  if(previous!=null){
   _validate(previous);
   if(!replaceVerified||previous['state']!='active'||previous['domain']!=credential.domain||previous['endpoint']!=credential.endpoint||previous['uid']!=credential.uid)return false;
   expectedRevision=previous['revision'] as int;
  }
  final desired=_record((expectedRevision??0)+1,'active',credential);
  bool saved;
  try{saved=await store.compareExchange(key,expectedRevision,desired);}
  catch(_){
   _retire(key);_blocked.add(key);
   // Security may commit and then fail readback. Clean only our exact record;
   // an unavailable store is explicitly unresolved, never assumed rolled back.
   try{
    final row=await store.read(key),expected=desired;
    if(row!=null&&row.length==expected.length&&expected.entries.every((e)=>row[e.key]==e.value))await revoke(key);
   }catch(_){throw StateError('Credential save cleanup unresolved');}
   throw StateError('Credential save failed');
  }
  if(saved&&!admitted()){await revoke(key);return false;}
  return saved&&admitted();
 }
 Future<WorkBuddyVaultLease?> restore(String key,{required Future<bool> Function(WorkBuddyVaultCredential,bool Function()) verify})async{
  final epoch=_retire(key);if(!_current(key,epoch))return null;
  try{
   final row=await store.read(key);if(row==null)return null;_validate(row);
   if(row['state']!='active')return null;
   final credential=WorkBuddyVaultCredential.decode(row);
   bool admitted()=>_current(key,epoch)&&now().isBefore(credential.expiresAt);
   if(!admitted()||!await verify(credential,admitted)||!admitted())return null;
   // Revocation/rotation may have happened during asynchronous verification.
   final after=await store.read(key);
   if(after==null||after['revision']!=row['revision']||after['state']!='active'||!_current(key,epoch)||!now().isBefore(credential.expiresAt))return null;
   return WorkBuddyVaultLease._(credential,admitted,()async{
    if(!admitted())return false;
    try{final latest=await store.read(key);final valid=admitted()&&latest!=null&&latest['revision']==row['revision']&&latest['state']=='active';if(!valid)_retire(key);return valid;}catch(_){_retire(key);return false;}
   });
  }catch(_){_retire(key);return null;}
 }
 Future<WorkBuddyRotationTicket?> beginRotation(String key)async{
  final epoch=_retire(key);if(!_current(key,epoch))return null;
  final row=await store.read(key);if(row==null)return null;_validate(row);if(row['state']!='active'||!_current(key,epoch))return null;
  final c=WorkBuddyVaultCredential.decode(row);if(c.refreshToken==null)return null;
  final revision=(row['revision'] as int)+1;
  // Durable uncertainty marker MUST precede any future refresh transmission.
  if(!await store.compareExchange(key,row['revision'] as int,_record(revision,'rotationPending',c)))return null;
  if(!_current(key,epoch))return null;
  return WorkBuddyRotationTicket._(key,revision,_owner);
 }
 Future<bool> completeRotation(WorkBuddyRotationTicket ticket,WorkBuddyVaultCredential replacement)async{
  if(_closed||!identical(ticket._owner,_owner)||_blocked.contains(ticket._key))return false;
  WorkBuddyVaultCredential.decode(replacement._encode());
  if(!now().isBefore(replacement.expiresAt))return false;
  final row=await store.read(ticket._key);if(row==null)return false;_validate(row);
  if(_closed||_blocked.contains(ticket._key)||row['revision']!=ticket._revision||row['state']!='rotationPending'||row['domain']!=replacement.domain||row['endpoint']!=replacement.endpoint||row['uid']!=replacement.uid)return false;
  return store.compareExchange(ticket._key,ticket._revision,_record(ticket._revision+1,'active',replacement));
 }
 Future<void> revoke(String key)async{
  _retire(key);_blocked.add(key); // Failures cannot revive this process's lease.
  // A missing record also gets a tombstone; concurrent save cannot resurrect.
  for(var attempt=0;attempt<3;attempt++){
   final row=await store.read(key);if(row!=null)_validate(row);
   if(row?['state']=='revoked')return;
   final revision=row?['revision'] as int?;
   if(await store.compareExchange(key,revision,_record((revision??0)+1,'revoked')))return;
  }
  throw StateError('Local revocation unresolved');
  // Credential-free tombstone persists. Claim intent journal is untouched.
 }
 void close(){_closed=true;for(final key in _epochs.keys.toList()){_retire(key);_blocked.add(key);}}
}
