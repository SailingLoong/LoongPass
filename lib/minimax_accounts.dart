// Minimal Dart port of LoongPort MiniMax native_import/auth/checkin business flow.
// Credentials go only to the supplied system Keychain functions. Metadata and
// claim receipts use one private JSON file; no new runtime/database/encryption.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'minimax_http.dart';
import 'source_digest.dart';

class MiniMaxAccountError implements Exception {
  final String code;
  const MiniMaxAccountError(this.code);
  @override String toString() => code;
}
enum _Region {cn, global}
class MiniMaxCredential {
  final String region, fingerprint, _accessToken;
  final int generation, expiresAtMs;
  MiniMaxCredential._(this.region,this.fingerprint,this._accessToken,this.generation,this.expiresAtMs);
  static MiniMaxCredential parse(Uint8List bytes,{required String sourcePath,required String region,required int nowMs}) {
    if(!['cn','global'].contains(region) || !_safeInt(nowMs)) throw const MiniMaxAccountError('InvalidImport');
    return _parseCandidate(bytes,sourcePath,region=='cn'?_Region.cn:_Region.global,nowMs);
  }
  @override String toString()=>'MiniMaxCredential(redacted)';
}
class MiniMaxVerifiedImport {
  final MiniMaxAccounts _owner;
  final Future<MiniMaxCredential> Function() _read;
  final MiniMaxCredential _credential;
  final String uid,label,id;
  final int? _previousGeneration;
  bool _consumed=false;
  MiniMaxVerifiedImport._(this._owner,this._read,this._credential,this.uid,this.label,this.id,this._previousGeneration);
  @override String toString()=>'MiniMaxVerifiedImport(redacted)';
}
class MiniMaxAccount {
  final String id,status,uid,region,label;
  final bool automatic;
  final num? points;
  final int expiresAtMs;
  MiniMaxAccount._(Map<String,dynamic> a):id=a['id'],status=a['status'],uid=a['uid'],region=a['region'],label=a['label'],automatic=a['automatic'],points=(a['operation'] as Map?)?['points'],expiresAtMs=a['expiresAtMs'];
  Map<String,Object?> toJson()=>{'id':id,'uid':uid,'label':label,'region':region,'status':status,'automatic':automatic,'points':points,'expiresAtMs':expiresAtMs};
  @override String toString()=>'MiniMaxAccount(redacted)';
}

/// App-owned NONSECRET state. root comes from prepareMiniMaxJournal; directory
/// fsync comes from syncMiniMaxJournal. Synthetic tests supply a no-op fsync,
/// which is not evidence of macOS durability. Only the single owning isolate
/// may use this object (POSIX locks do not serialize isolates in one process).
class MiniMaxMetadataStore {
  final Directory root;
  final Future<void> Function() syncDirectory;
  static final _busy=<String>{};
  MiniMaxMetadataStore(this.root,{required this.syncDirectory});
  Future<T> _access<T>(Future<T> Function(Map<String,dynamic>) action,{bool write=false}) async {
    final path=root.absolute.path;
    if(!_busy.add(path))throw const MiniMaxAccountError('Busy');
    RandomAccessFile? lock;
    try {
      if(await FileSystemEntity.type(path,followLinks:false)!=FileSystemEntityType.directory || (await root.stat()).mode&0x3f!=0 || await root.resolveSymbolicLinks()!=path)throw const MiniMaxAccountError('StorageUnavailable');
      final lockFile=File('$path/minimax.lock');
      final lockType=await FileSystemEntity.type(lockFile.path,followLinks:false);
      if(lockType!=FileSystemEntityType.notFound&&lockType!=FileSystemEntityType.file)throw const MiniMaxAccountError('StorageUnavailable');
      lock=await lockFile.open(mode:FileMode.append);
      await lock.lock(FileLock.blockingExclusive);
      final file=File('$path/minimax-accounts.json');
      final type=await FileSystemEntity.type(file.path,followLinks:false);
      Map<String,dynamic> doc={'version':1,'accounts':<String,dynamic>{}};
      if(type!=FileSystemEntityType.notFound) {
        if(type!=FileSystemEntityType.file||await file.length()>4*1024*1024)throw const MiniMaxAccountError('StorageUnavailable');
        doc=jsonDecode(await file.readAsString()) as Map<String,dynamic>;
      }
      _validateMetadata(doc);
      final accounts=doc['accounts'] as Map<String,dynamic>;
      final result=await action(accounts);
      if(write) {
        _validateMetadata(doc);
        final stage=await root.createTemp('.minimax-write-');
        try {
          final temp=File('${stage.path}/metadata.json');
          await temp.writeAsString(jsonEncode(doc),flush:true);
          await temp.rename(file.path);
          await syncDirectory();
        } finally {await stage.delete(recursive:true);}
      }
      return result;
    } on MiniMaxAccountError {rethrow;} catch(_){throw const MiniMaxAccountError('StorageUnavailable');}
    finally {if(lock!=null){try{await lock.unlock();}catch(_){}try{await lock.close();}catch(_){}}_busy.remove(path);}
  }
  static void _validateMetadata(Map<String,dynamic> doc) {
    if(doc['version']!=1||doc['accounts'] is! Map<String,dynamic>||doc.keys.any((k)=>!['version','accounts'].contains(k)))throw const MiniMaxAccountError('StorageUnavailable');
    const keys={'id','uid','label','region','generation','expiresAtMs','secretRef','automatic','policyRevision','status','operation','sourceGeneration','sourceFingerprint'};
    for(final e in (doc['accounts'] as Map<String,dynamic>).entries) {
      final a=e.value;
      if(a is! Map<String,dynamic>||a.keys.any((k)=>!keys.contains(k))||a['id']!=e.key||!['cn','global'].contains(a['region'])||a['uid'] is! String||a['label'] is! String||a['generation'] is! int||a['expiresAtMs'] is! int||a['secretRef'] is! String||a['automatic'] is! bool||a['policyRevision'] is! int||!['unavailable','claimable','claimed','alreadyClaimed','unknown','needsLogin'].contains(a['status']))throw const MiniMaxAccountError('StorageUnavailable');
      final op=a['operation'];
      if(op!=null&&(op is! Map||op.keys.any((k)=>!['id','day','state','points','claimId'].contains(k))||op['id'] is! String||op['day'] is! String||!['pending','unknown','claimed','alreadyClaimed'].contains(op['state'])))throw const MiniMaxAccountError('StorageUnavailable');
    }
  }
}

class MiniMaxAccounts {
  final MiniMaxMetadataStore store;
  final Future<String?> Function(String) readSecret;
  final Future<void> Function(String,String) writeSecret;
  final Future<void> Function(String) deleteSecret;
  final MiniMaxHttp http;
  final int Function() nowMs;
  final FutureOr<void> Function()? onAutomaticFinished;
  static final _busy=<String>{};
  bool _closed=false,_ticking=false;
  Timer? _startupTimer,_timer;
  MiniMaxAccounts({required this.store,required this.readSecret,required this.writeSecret,required this.deleteSecret,this.onAutomaticFinished,MiniMaxHttp? http,int Function()? nowMs}):http=http??MiniMaxHttp(),nowMs=nowMs??(()=>DateTime.now().millisecondsSinceEpoch);
  void _alive(){if(_closed)throw const MiniMaxAccountError('Closed');}
  String _ownerKey(String id)=>'${store.root.absolute.path}\u0000$id';
  String _day()=>DateTime.fromMillisecondsSinceEpoch(nowMs(),isUtc:true).toIso8601String().substring(0,10);
  Future<MiniMaxReply> _send(MiniMaxEndpoint endpoint,String token,String region,[String? uid,bool Function()? admission])async{
    _alive();
    try {final r=await http.send(endpoint,accessToken:token,region:region,userId:uid,isCurrent:()=>!_closed&&(admission?.call()??true));_alive();return r;}
    on MiniMaxAccountError {rethrow;}
    catch(_){throw const MiniMaxAccountError('NetworkUnavailable');}
  }
  Future<MiniMaxVerifiedImport> verifySource(Future<MiniMaxCredential> Function() read,{required bool confirmed})async{
    if(!confirmed)throw const MiniMaxAccountError('ConfirmationRequired');_alive();
    final before=await store._access((a)async=>{for(final e in a.entries)e.key:(e.value as Map)['generation']});
    final c=await read();_alive();if(c.expiresAtMs<=nowMs())throw const MiniMaxAccountError('NeedsLogin');
    final profile=_profile(await _send(MiniMaxEndpoint.profile,c._accessToken,c.region));
    final again=await read();_alive();if(again.fingerprint!=c.fingerprint||again.region!=c.region)throw const MiniMaxAccountError('SourceChanged');
    final key='${c.region}:${sourceSha256(utf8.encode('${c.region}\u0000${profile.$1}')).map((v)=>v.toRadixString(16).padLeft(2,'0')).join()}';
    return MiniMaxVerifiedImport._(this,read,c,profile.$1,profile.$2,key,before[key] as int?);
  }
  Future<MiniMaxVerifiedImport> verifyFile(String path,{required String region,required bool confirmed})=>verifySource(()=>readMiniMaxCredentialFile(path,region:region,nowMs:nowMs()),confirmed:confirmed);
  Future<MiniMaxAccount> save(MiniMaxVerifiedImport value,{required bool confirmed})async{
    if(!confirmed)throw const MiniMaxAccountError('ConfirmationRequired');_alive();
    if(value._owner!=this)throw const MiniMaxAccountError('SourceChanged');
    if(value._consumed)throw const MiniMaxAccountError('ImportCompleted');
    if(!_busy.add(_ownerKey(value.id)))throw const MiniMaxAccountError('Busy');
    try {
    value._consumed=true;
    final c=await value._read();_alive();
    if(c.fingerprint!=value._credential.fingerprint||c.region!=value._credential.region)throw const MiniMaxAccountError('SourceChanged');
    if(c.expiresAtMs<=nowMs())throw const MiniMaxAccountError('NeedsLogin');
    return await store._access((accounts)async{
      final old=accounts[value.id] as Map?;
      if(old?['generation']!=value._previousGeneration)throw const MiniMaxAccountError('SourceChanged');
      final generation=(old?['generation'] as int? ??0)+1;
      final secretRef='${c.region}:${sourceSha256(utf8.encode('${value.id}\u0000$generation\u0000${_nonce()}')).map((v)=>v.toRadixString(16).padLeft(2,'0')).join()}';
      try{await writeSecret(secretRef,c._accessToken);}catch(_){throw const MiniMaxAccountError('KeychainUnavailable');}
      try {
        _alive();final last=await value._read();_alive();
        if(last.fingerprint!=c.fingerprint||last.expiresAtMs<=nowMs())throw const MiniMaxAccountError('SourceChanged');
      }catch(_){try{await deleteSecret(secretRef);}catch(_){}rethrow;}
      // New secret reference avoids overwriting an existing account if metadata
      // publication fails. An uncertain disk outcome never deletes that secret.
      final operation=old?['operation'];
      final account=<String,dynamic>{'id':value.id,'uid':value.uid,'label':value.label,'region':c.region,'generation':generation,'expiresAtMs':c.expiresAtMs,'secretRef':secretRef,'automatic':false,'policyRevision':(old?['policyRevision'] as int? ??0)+1,'status':_unresolved(operation)?'unknown':'unavailable','operation':operation,'sourceGeneration':c.generation,'sourceFingerprint':c.fingerprint};
      accounts[value.id]=account;return MiniMaxAccount._(account);
    },write:true);
    }finally{_busy.remove(_ownerKey(value.id));}
  }
  Future<List<MiniMaxAccount>> list()async{_alive();return store._access((a)async=>[for(final v in a.values)MiniMaxAccount._(v as Map<String,dynamic>)]);}
  Future<Map<String,dynamic>> _account(String id)=>store._access((a)async{final value=a[id];if(value is! Map<String,dynamic>)throw const MiniMaxAccountError('AccountMissing');return Map<String,dynamic>.from(value);});
  Future<MiniMaxAccount> setAutomatic(String id,bool enabled)async{_alive();if(!_busy.add(_ownerKey(id)))throw const MiniMaxAccountError('Busy');try{return await store._access((a)async{final row=a[id] as Map<String,dynamic>?;if(row==null)throw const MiniMaxAccountError('AccountMissing');row['automatic']=enabled;row['policyRevision']=(row['policyRevision'] as int)+1;return MiniMaxAccount._(row);},write:true);}finally{_busy.remove(_ownerKey(id));}}
  Future<MiniMaxAccount> claim(String id)=>_claim(id,false);
  Future<MiniMaxAccount> _claim(String id,bool automatic)async{
    _alive();if(!_busy.add(_ownerKey(id)))throw const MiniMaxAccountError('Busy');
    try {
      final account=await _account(id);_alive();
      if(automatic&&account['automatic']!=true)return MiniMaxAccount._(account);
      if(_unresolved(account['operation'])||(account['operation'] as Map?)?['day']==_day())return MiniMaxAccount._(account);
      if((account['expiresAtMs'] as int)<=nowMs())throw const MiniMaxAccountError('NeedsLogin');
      String? token;try{token=await readSecret(account['secretRef']);}catch(_){throw const MiniMaxAccountError('KeychainUnavailable');}
      if(token==null||token.isEmpty)throw const MiniMaxAccountError('NeedsLogin');
      final statusDay=_day();
      final status=_panel(_data(await _send(MiniMaxEndpoint.status,token,account['region'],account['uid'])),automatic:automatic);
      if((account['expiresAtMs'] as int)<=nowMs())throw const MiniMaxAccountError('NeedsLogin');
      if(statusDay!=_day())throw const MiniMaxAccountError('StatusExpired');
      final opId=_nonce();
      final prepared=await store._access((a)async{
        _alive();final current=_match(a,id,account);
        if(automatic&&(current['automatic']!=true||current['policyRevision']!=account['policyRevision']))throw const MiniMaxAccountError('AutomaticDisabled');
        if(_unresolved(current['operation'])||(current['operation'] as Map?)?['day']==_day())return false;
        current['status']=status;
        if(status!='claimable')return false;
        current['operation']={'id':opId,'day':_day(),'state':'pending','points':null,'claimId':null};current['status']='unknown';return true;
      },write:true);
      if(!prepared)return MiniMaxAccount._(await _account(id));
      // Pending marker is durably published before the one POST. Re-check the
      // current identity and opt-in after persistence; never auto-replay POST.
      await store._access((a)async{_alive();final current=_match(a,id,account);if((current['operation'] as Map?)?['id']!=opId)throw const MiniMaxAccountError('SourceChanged');if(automatic&&(current['automatic']!=true||current['policyRevision']!=account['policyRevision']))throw const MiniMaxAccountError('AutomaticDisabled');return null;});
      if((account['expiresAtMs'] as int)<=nowMs())throw const MiniMaxAccountError('NeedsLogin');
      if(statusDay!=_day())throw const MiniMaxAccountError('StatusExpired');
      (String,num,String)? receipt;
      try{receipt=_receipt(await _send(MiniMaxEndpoint.claim,token,account['region'],account['uid'],()=>(account['expiresAtMs'] as int)>nowMs()&&statusDay==_day()));}catch(_){/* Pending remains unknown; no POST retry. */}
      _alive();
      return store._access((a)async{
        _alive();final current=_match(a,id,account);final op=current['operation'] as Map;
        if(op['id']!=opId)throw const MiniMaxAccountError('SourceChanged');
        op['state']=receipt?.$1??'unknown';op['points']=receipt?.$2;op['claimId']=receipt?.$3;current['status']=receipt?.$1??'unknown';return MiniMaxAccount._(current);
      },write:true);
    }finally{_busy.remove(_ownerKey(id));}
  }
  Future<void> automaticTick()async{
    _alive();if(_ticking)return;_ticking=true;
    try{for(final a in await list()){if(_closed)break;if(a.automatic){try{await _claim(a.id,true);}catch(_){/* surfaced on explicit action/list; no replay loop */}}}}finally{try{if(!_closed)await onAutomaticFinished?.call();}catch(_){/* UI refresh must not change the claim outcome. */}finally{_ticking=false;}}
  }
  /// Existing in-process schedule, no new service. Only persisted account opt-ins
  /// are acted on. Stops when app/session closes; not an OS background daemon.
  void startAutomatic(){_alive();if(_timer!=null||_startupTimer!=null)return;_startupTimer=Timer(const Duration(seconds:30),(){_startupTimer=null;if(!_closed)unawaited(automaticTick().catchError((_){ }));});_timer=Timer.periodic(const Duration(minutes:15),(_){if(!_closed)unawaited(automaticTick().catchError((_){ }));});}
  void dispose(){_closed=true;_startupTimer?.cancel();_timer?.cancel();_startupTimer=null;_timer=null;}
}
String _nonce()=>List.generate(16,(_)=>Random.secure().nextInt(256).toRadixString(16).padLeft(2,'0')).join();
bool _unresolved(Object? op)=>op is Map&&['pending','unknown'].contains(op['state']);
Map<String,dynamic> _match(Map<String,dynamic> accounts,String id,Map<String,dynamic> expected){final c=accounts[id];if(c is! Map<String,dynamic>||c['generation']!=expected['generation']||c['secretRef']!=expected['secretRef'])throw const MiniMaxAccountError('SourceChanged');return c;}
(String,String) _profile(MiniMaxReply r){
 if(r.status==401||r.status==403)throw const MiniMaxAccountError('NeedsLogin');
 final b=r.body;if(r.status<200||r.status>=300||b==null)throw const MiniMaxAccountError('InvalidResponse');
 for(final pair in [('statusInfo','code'),('base_resp','status_code')]){final section=b[pair.$1];if(section is Map&&section.containsKey(pair.$2)){final code=section[pair.$2];if(code==1000048)throw const MiniMaxAccountError('NeedsLogin');if(code is! int||code!=0)throw const MiniMaxAccountError('InvalidResponse');}}
 final data=b['data'];final p=(data is Map?(data['userInfo']??data['user_info']):null)??b['userInfo']??b['user_info'];
 if(p is! Map)throw const MiniMaxAccountError('InvalidResponse');
 final uid=p['realUserID']??p['real_user_id'];if(!_validText(uid,256))throw const MiniMaxAccountError('InvalidResponse');
 final label=p['name']??p['userName']??p['user_name']??p['email']??uid;
 return (uid as String,_validText(label,16384)?String.fromCharCodes((label as String).runes.take(160)):uid);
}
Map _data(MiniMaxReply r){if(r.status==401||r.status==403)throw const MiniMaxAccountError('NeedsLogin');final b=r.body;if(r.status<200||r.status>=300||b==null||b['base_resp'] is! Map||(b['base_resp'] as Map)['status_code'] is! int||(b['base_resp'] as Map)['status_code']!=0||b['data'] is! Map)throw const MiniMaxAccountError('InvalidResponse');return b['data'] as Map;}
bool _finite(Object? n)=>n is num&&n.isFinite&&n>=0;
String _panel(Map p,{bool automatic=false}){
 final scene=p['scene'],days=p['days'];if(scene is! int||scene<0||scene>4||days is! List||days.length!=7)throw const MiniMaxAccountError('InvalidResponse');
 final numbers=<int>{};var claimable=0,today=0;bool todayClaimed=false,todayClaimable=false;
 for(final d in days){if(d is! Map||d['day_no'] is! int||d['day_no']<1||d['day_no']>7||!numbers.add(d['day_no'])||!_finite(d['points'])||(d['bonus_points']!=null&&!_finite(d['bonus_points']))||d['status'] is! int||d['status']<1||d['status']>4||d['is_today'] is! bool)throw const MiniMaxAccountError('InvalidResponse');if(d['status']==2)claimable++;if(d['is_today']){today++;todayClaimed=d['status']==3;todayClaimable=d['status']==2;}}
 if(claimable>1||today>1)throw const MiniMaxAccountError('InvalidResponse');
 return todayClaimed?'alreadyClaimed':claimable==1&&(!automatic||todayClaimable)?'claimable':'unavailable';
}
(String,num,String) _receipt(MiniMaxReply r){final d=_data(r);if(d['panel'] is! Map)throw const MiniMaxAccountError('InvalidResponse');_panel(d['panel']);final id=d['claim_id'],result=d['claim_result'],day=d['day_no'];if(!_validText(id,1024)||result is! int||!{1,2}.contains(result)||day is! int||day<1||day>7||!_finite(d['points'])||d['expire_at_ms'] is! num||!(d['expire_at_ms'] as num).isFinite)throw const MiniMaxAccountError('InvalidResponse');return(result==1?'claimed':'alreadyClaimed',d['points'] as num,id as String);}

/// Only the user-selected file. No default scanning, version/signature gates or
/// refresh writes. Dart checks ordinary source replacement; hostile same-UID
/// filesystem races require the existing native reader when integrated.
Future<MiniMaxCredential> readMiniMaxCredentialFile(String path,{required String region,required int nowMs})async{
 try {
  final file=File(path);if(file.absolute.path!=path)throw const MiniMaxAccountError('InvalidImport');
  for(var d=file.parent;;d=d.parent){if(await FileSystemEntity.type(d.path,followLinks:false)!=FileSystemEntityType.directory)throw const MiniMaxAccountError('InvalidImport');if(d.parent.path==d.path)break;}
  if(await FileSystemEntity.type(path,followLinks:false)!=FileSystemEntityType.file)throw const MiniMaxAccountError('InvalidImport');
  final before=await file.stat();if(before.size>1048576||(before.mode&0x3f)!=0)throw const MiniMaxAccountError('InvalidImport');
  final out=BytesBuilder(copy:false);await for(final part in file.openRead()){if(out.length+part.length>1048576)throw const MiniMaxAccountError('InvalidImport');out.add(part);}
  final after=await file.stat();if(await FileSystemEntity.type(path,followLinks:false)!=FileSystemEntityType.file||before.size!=after.size||before.modified!=after.modified||before.changed!=after.changed||before.mode!=after.mode)throw const MiniMaxAccountError('SourceChanged');
  final bytes=out.takeBytes();try{return MiniMaxCredential.parse(bytes,sourcePath:path,region:region,nowMs:nowMs);}finally{bytes.fillRange(0,bytes.length,0);}
 }on MiniMaxAccountError {rethrow;}catch(_){throw const MiniMaxAccountError('InvalidImport');}
}

const _maxBytes=1024*1024;
bool _safeInt(Object? v) => v is int && v>=0 && v<=9007199254740991;
bool _validText(Object? v,int maxBytes) => v is String && v.isNotEmpty && v.trim()==v && utf8.encode(v).length<=maxBytes && !v.runes.any((c)=>c<32 || (c>=127 && c<=159));
String _text(Map v,String key,{int maxBytes=16384}) {
  final value=v[key];
  if(!_validText(value,maxBytes)) throw const MiniMaxAccountError('InvalidImport');
  return value as String;
}
String _fingerprint(Uint8List bytes) => base64Url.encode(sourceSha256(bytes));
String _sourceHome(String path, _Region region) {
  final suffix='/prod/${region==_Region.cn?'cn':'en'}/mcode-public/auth.json';
  if(!_validText(path,4096) || !path.startsWith('/') || !path.endsWith(suffix) || path.contains(r'\')) throw const MiniMaxAccountError('UnsupportedSource');
  final parts=path.substring(1).split('/');
  if(parts.any((p)=>p.isEmpty || p=='.' || p=='..')) throw const MiniMaxAccountError('UnsupportedSource');
  final home=path.substring(0,path.length-suffix.length);
  if(home.isEmpty) throw const MiniMaxAccountError('UnsupportedSource');
  return home;
}
MiniMaxCredential _parseCandidate(Uint8List bytes,String path,_Region region,int nowMs) {
  if(bytes.length>_maxBytes) throw const MiniMaxAccountError('InvalidImport');
  final home=_sourceHome(path,region);
  Map v;
  try {
    final raw=utf8.decode(bytes);
    _rejectDuplicateKeys(raw);
    final decoded=jsonDecode(raw);
    if(decoded is! Map) throw const FormatException();
    v=decoded;
  } on FormatException {
    throw const MiniMaxAccountError('InvalidImport');
  }
  if(v['schemaVersion'] is! int || v['schemaVersion']!=1 || v['records'] is! Map) throw const MiniMaxAccountError('InvalidImport');
  final account=base64Url.encode(sourceSha256(utf8.encode('$home\u0000mcode-public'))).replaceAll('=','');
  final key='com.minimax.mcode.oauth.prod.${region==_Region.cn?'cn':'en'}\u0000$account';
  final c=(v['records'] as Map)[key];
  if(c==null) throw const MiniMaxAccountError('SourceMismatch');
  if(c is! Map || c['schemaVersion'] is! int || c['schemaVersion']!=1) throw const MiniMaxAccountError('InvalidImport');
  if(_text(c,'clientId')!='mcode-public' || _text(c,'audience')!='agent-backend' || _text(c,'tokenType')!='Bearer') throw const MiniMaxAccountError('SourceMismatch');
  final scopes=c['scopes'];
  if(scopes is! List || !scopes.every((v)=>v is String)) throw const MiniMaxAccountError('InvalidImport');
  if(!scopes.contains('agent.default')) throw const MiniMaxAccountError('SourceMismatch');
  final accessToken=_text(c,'accessToken');
  _text(c,'refreshToken'); // Validate format only; never retain or refresh it.
  final generation=c['generation'],expiry=c['expiresAtMs'];
  if(!_safeInt(generation) || !_safeInt(expiry)) throw const MiniMaxAccountError('InvalidImport');
  if((expiry as int)<=nowMs) throw const MiniMaxAccountError('NeedsLogin');
  if(c.containsKey('subject')) {
    _text(c,'subject',maxBytes:256);
  }
  if(c.containsKey('accountId')) _text(c,'accountId');
  if(c.containsKey('loginEpoch')) _text(c,'loginEpoch');
  return MiniMaxCredential._(region==_Region.cn?'cn':'global',_fingerprint(Uint8List.fromList([...utf8.encode('$path\u0000${region.name}\u0000'),...bytes])),accessToken,generation as int,expiry);
}

// Reject ambiguous JSON keys before dart:convert's last-key-wins decoding.
// Adapted from LoongPass's strict Qoder decoder; bounded iterative scan.
void _rejectDuplicateKeys(String text) {
  final stack=<Set<String>?>[];
  var offset=0;
  while(offset<text.length) {
    final char=text[offset];
    if(char=='"') {
      final start=offset++;
      var closed=false;
      while(offset<text.length) {
        final unit=text[offset++];
        if(unit==r'\') {offset++;} else if(unit=='"') {closed=true;break;}
      }
      if(!closed) throw const FormatException();
      var next=offset;
      while(next<text.length && ' \t\r\n'.contains(text[next])){next++;}
      if(next<text.length && text[next]==':') {
        final key=jsonDecode(text.substring(start,offset)) as String;
        if(stack.isEmpty || stack.last==null || !stack.last!.add(key)) throw const FormatException();
      }
      continue;
    }
    if(char=='{' || char=='[') {
      if(stack.length>=128) throw const FormatException();
      stack.add(char=='{'?<String>{}:null);
    } else if(char=='}' || char==']') {
      if(stack.isEmpty) throw const FormatException();
      stack.removeLast();
    }
    offset++;
  }
  if(stack.isNotEmpty) throw const FormatException();
}
