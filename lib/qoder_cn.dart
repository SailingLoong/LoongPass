// CN independent grants and explicit free benefits. MIT-derived protocol:
// candidate-669 qoder_cn_device_login, qoder_http_auth/transport,
// qoder_daily/cn_benefits{,_contract}. No desktop auth-file access.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
abstract interface class CnNative { Future<Map<String,dynamic>> call(String method, Map<String,dynamic> args); }
abstract interface class CnTransport { Future<CnResponse> send(String method, Uri url, String? bearer, Map<String,dynamic>? body); }
class CnResponse { final int status; final Map<String,dynamic> body; final int? serverMs; CnResponse(this.status,this.body,{this.serverMs}); @override String toString()=>'CnResponse(redacted)'; }
class CnFailure implements Exception {final String code; const CnFailure(this.code); @override String toString()=>'Qoder CN: $code';}
class CnLogin {final Uri url; CnLogin(this.url); @override String toString()=>'CnLogin(redacted)';}
/// Production network adapter. Origin is fixed; no redirects, retries or logs.
class CnHttp implements CnTransport {
 @override Future<CnResponse> send(String method,Uri url,String? bearer,Map<String,dynamic>? body)async{
  if(url.scheme!='https'||url.host!='openapi.qoder.com.cn'||url.port!=443||url.userInfo.isNotEmpty||url.fragment.isNotEmpty)throw const CnFailure('invalid_source');
  final client=HttpClient()..connectionTimeout=const Duration(seconds:20);
  try{return await (()async{
   final req=await client.openUrl(method,url);req.followRedirects=false;
   req.headers.set('Accept','application/json');req.headers.contentType=ContentType.json;
   final campaign=url.path.startsWith('/sash/');req.headers.set('Cosy-ClientType',campaign?'10':'5');
   req.headers.set('User-Agent',campaign?'Qoder':'LoongPass');if(!campaign)req.headers.set('Cosy-Version','1.0.1');
   if(bearer!=null)req.headers.set('Authorization','Bearer $bearer');if(body!=null)req.write(jsonEncode(body));
   final response=await req.close();if(response.isRedirect||response.statusCode>=300&&response.statusCode<400)throw const CnFailure('redirect_rejected');
   final bytes=<int>[];final limit=campaign?262144:1048576;
   await for(final chunk in response){if(bytes.length+chunk.length>limit)throw const CnFailure('response_too_large');bytes.addAll(chunk);}
   if(response.statusCode==404&&url.path=='/api/v1/deviceToken/poll')return CnResponse(404,{});
   if(response.statusCode!=200)throw CnFailure(response.statusCode==401?'authentication_required':response.statusCode==403?'verification_required':response.statusCode==429?'rate_limited':'http_error');
   final value=jsonDecode(utf8.decode(bytes));if(value is! Map<String,dynamic>)throw const CnFailure('invalid_response');
   int? server;try{final date=response.headers.value('date');if(date!=null)server=HttpDate.parse(date).millisecondsSinceEpoch;}catch(_){}
   return CnResponse(response.statusCode,value,serverMs:server);
  })().timeout(const Duration(seconds:30));}on CnFailure{rethrow;}catch(_){throw const CnFailure('network_error');}finally{client.close(force:true);}
 }
}
class _Store {int revision;final Map<String,dynamic> data;_Store(this.revision,this.data);}
class _Grant {final Map<String,dynamic> material;final int expires;final _Store store;int? lastPoll;bool polling=false;_Grant(this.material,this.expires,this.store);@override String toString()=>'Grant(redacted)';}
class QoderCn {
 final CnNative _native;final CnTransport _http;final int Function() _now;
 _Grant? _grant;String? _commitNonce,_commitOutcome;bool _starting=false,_claiming=false;int _cancelEpoch=0;
 QoderCn({required CnNative native,required CnTransport transport,required int Function() nowMs}):_native=native,_http=transport,_now=nowMs;
 static const _clientId='e883ade2-e6e3-4d6d-adf7-f92ceff5fdcb';
 static Uri _url(String path,[Map<String,String>? query])=>Uri.https('openapi.qoder.com.cn',path,query);
 static bool _text(Object? v,{int max=16384})=>v is String&&v.trim().isNotEmpty&&v.length<=max&&!v.codeUnits.any((c)=>c<32||c==127);
 static bool _uuid(Object? v)=>v is String&&RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$').hasMatch(v);
 Future<Map<String,dynamic>> _nativeCall(String method,Map<String,dynamic> args)async{try{return await _native.call(method,args);}catch(_){throw const CnFailure('storage_unavailable');}}
 Future<_Store> _read()async{
  final raw=await _nativeCall('read',{});
  try{
   final payload=raw['payload'];if(raw['revision'] is! int||raw['revision']<0||payload is! String||utf8.encode(payload).length>1048576)throw 0;
   final data=jsonDecode(payload);if(data is! Map<String,dynamic>)throw 0;
   if(data.isEmpty){data['accounts']=<String,dynamic>{};data['claims']=<String,dynamic>{};}
   if(data['accounts'] is! Map<String,dynamic>||data['claims'] is! Map<String,dynamic>||(data['accounts'] as Map).length>100)throw 0;
   for(final e in (data['accounts'] as Map<String,dynamic>).entries){final a=e.value;if(!_text(e.key,max:1024)||a is! Map||!_text(a['token'])||!_text(a['refreshToken']==''?'empty':a['refreshToken'])||a['expiresAt'] is! int||a['expiresAt']<=0||!_uuid(a['machineId'])||!_uuid(a['generation']))throw 0;}
   for(final v in (data['claims'] as Map).values){if(v is! Map||!{'pending','unknown','claimed','reconciled'}.contains(v['state']))throw 0;}
   return _Store(raw['revision'],data);
  }catch(_){throw const CnFailure('invalid_storage');}
 }
 Future<void> _save(_Store s,{String? nonce})async{
  final out=await _nativeCall(nonce==null?'compareAndSet':'commitGrant',{'expectedRevision':s.revision,'payload':jsonEncode(s.data),if(nonce!=null)'nonce':nonce});
  if(out['revision']!=s.revision+1)throw const CnFailure('storage_unavailable');s.revision++;
 }
 /// Must be invoked only for the user's explicit sign-in action. Saving the
 /// resulting persistent grant requires the host's action-time confirmation.
 Future<CnLogin> startLogin()async{
  if(_starting||_grant!=null)throw const CnFailure('login_busy');_starting=true;final epoch=_cancelEpoch;
  try{
   final now=_now();if(now<0)throw const CnFailure('clock_invalid');
   final store=await _read();if(epoch!=_cancelEpoch)throw const CnFailure('cancelled');
   final m=await _nativeCall('newGrant',{});if(epoch!=_cancelEpoch){await _nativeCall('cancelGrant',{'nonce':m['nonce']});throw const CnFailure('cancelled');}
   if(!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(m['verifier'] is String?m['verifier']:'')||!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(m['challenge'] is String?m['challenge']:'')||!_uuid(m['nonce'])||!_uuid(m['machineId']))throw const CnFailure('invalid_grant');
   _commitNonce=null;_commitOutcome=null;_grant=_Grant(m,now+300000,store);
   return CnLogin(Uri.https('qoder.cn','/device/selectAccounts',{'challenge':m['challenge'],'challenge_method':'S256','nonce':m['nonce'],'machine_id':m['machineId'],'client_id':_clientId}));
  }finally{_starting=false;}
 }
 Future<String> cancelLogin()async{_cancelEpoch++;final g=_grant;_grant=null;if(g==null&&_commitOutcome!=null)return _commitOutcome!;final nonce=g?.material['nonce']??_commitNonce;if(nonce==null)return 'cancelled';try{final r=await _nativeCall('cancelGrant',{'nonce':nonce});final outcome=r['status']=='completed'?'completed':r['status']=='cancelled'?'cancelled':'unknown';if(nonce==_commitNonce)_commitOutcome=outcome;return outcome;}on CnFailure{return 'unknown';}}
 Future<String?> pollLogin()async{
  final g=_grant;if(g==null)throw const CnFailure('login_required');
  final now=_now();if(now<0||now>=g.expires){_grant=null;throw const CnFailure('expired');}
  if(g.polling||g.lastPoll!=null&&now-g.lastPoll!<1000)return null;g.polling=true;
  try{
   final result=await _http.send('GET',_url('/api/v1/deviceToken/poll',{'nonce':g.material['nonce'],'verifier':g.material['verifier'],'challenge_method':'S256'}),null,null);
   _checkGrant(g);if(result.status==404){g.lastPoll=_now();return null;}
   if(result.status!=200)throw const CnFailure('authentication_required');
   final b=result.body;final token=b['token'],refresh=b['refresh_token']??'';final uid=_uid(b['user_id']);
   if(!_text(token)||refresh is! String||refresh.isNotEmpty&&!_text(refresh))throw const CnFailure('invalid_response');
   int expiry;
   if(b['expires_at'] is String){final value=b['expires_at'] as String;if(!RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(value))throw const CnFailure('invalid_response');expiry=DateTime.parse(value).millisecondsSinceEpoch;}
   else if(b['expires_at']==null&&b['expires_in'] is int&&b['expires_in']>0){expiry=_now()+(b['expires_in'] as int)*1000;}
   else{throw const CnFailure('invalid_response');}
   if(expiry<=_now())throw const CnFailure('expired');
   final user=await _http.send('GET',_url('/api/v1/userinfo'),token,null);_checkGrant(g);
   if(user.status!=200||_uid(user.body['id']??user.body['user_id']??user.body['uid'])!=uid)throw const CnFailure('identity_mismatch');
   final store=g.store;_checkGrant(g);
   // The same UID keeps its durable claim history, including uncertain sends.
   store.data['accounts'][uid]={'token':token,'refreshToken':refresh,'expiresAt':expiry,'machineId':g.material['machineId'],'generation':g.material['nonce']};
   // No retry after the grant was consumed, even if the Keychain write outcome
   // is unknown. A fresh user sign-in is required on any failure.
   _commitNonce=g.material['nonce'];_commitOutcome='unknown';await _save(store,nonce:_commitNonce);_commitOutcome='completed';if(identical(_grant,g))_grant=null;return uid;
  }on CnFailure{if(identical(_grant,g))_grant=null;rethrow;}catch(_){if(identical(_grant,g))_grant=null;throw const CnFailure('invalid_response');}finally{g.polling=false;}
 }
 void _checkGrant(_Grant g){if(!identical(_grant,g))throw const CnFailure('cancelled');if(_now()<0||_now()>=g.expires)throw const CnFailure('expired');}
 static String _uid(Object? v){final value=v is num&&v.isFinite?v.toString():v;if(!_text(value,max:1024))throw const CnFailure('invalid_response');return value as String;}
 Future<List<String>> accounts()async=>List<String>.unmodifiable((await _read()).data['accounts'].keys.cast<String>());
 static void _envelope(Map b,String uid,{bool receipt=false}){
  final nested=b['data'];if(nested is Map){for(final k in ['code','status']){if(nested.containsKey(k)&&!['0','200','SUCCESS','OK',if(receipt&&k=='status')'CLAIMED'].contains(nested[k].toString()))throw const CnFailure('verification_required');}}
  if(b.containsKey('uid')&&b['uid']!=uid)throw const CnFailure('identity_mismatch');
  if(b.containsKey('success')&&b['success']!=true||b['error']!=null)throw const CnFailure('service_rejected');
  for(final k in ['code','status']){if(b.containsKey(k)&&!['0','200','SUCCESS','OK',if(receipt&&k=='status')'CLAIMED'].contains(b[k].toString()))throw const CnFailure('verification_required');}
 }
 static String? _skip(Map r,Set<String> duplicate){
  final id=r['campaignId'];if(!_text(id,max:256)||id=='.'||id=='..'||(id as String).contains(RegExp(r'[\u202a-\u202e\u2066-\u2069]')))return 'invalid_activity';
  if(r['campaignKey']!=null&&!_text(r['campaignKey'],max:256))return 'invalid_activity';
  if(duplicate.contains(id))return 'ambiguous_campaign';
  if(r['actionType']!='CLAIM_BENEFIT')return 'unsupported_action';
  if(r['unavailableReason']!=null&&r['unavailableReason']!='')return 'unavailable';
  if(r['requiredAchievementKey']!=null&&r['requiredAchievementKey']!=''&&r['achievementCompleted']!=true)return 'achievement_required';
  if(['purchaseRequired','subscriptionRequired','termsAcceptanceRequired'].any((k)=>r[k]!=null&&r[k]!=false)||r['creditsCost']!=null&&r['creditsCost']!=0)return 'additional_condition';
  for(final k in ['startAt','endAt']){if(r[k]!=null&&(r[k] is! int||r[k]<0||r[k]>253402300799))return 'invalid_activity';}
  if(r['startAt']!=null&&r['endAt']!=null&&r['startAt']>=r['endAt'])return 'invalid_activity';
  return null;
 }
 /// Explicit free-benefit action for one independently authorized CN account.
 /// No automatic scheduling, device spoofing, credential refresh or app switch.
 Future<List<Map<String,dynamic>>> claim(String uid)async{
  if(_claiming)throw const CnFailure('claim_busy');_claiming=true;
  try{
   final s=await _read();final a=s.data['accounts'][uid];if(a==null)throw const CnFailure('identity_required');if(_now()<0||a['expiresAt']<=_now())throw const CnFailure('identity_expired');
   final listing=await _http.send('GET',_url('/sash/api/v1/me/campaigns'),a['token'],null);final elapsed=Stopwatch()..start();
   if(listing.status!=200)throw const CnFailure('http_error');_envelope(listing.body,uid);
   final rows=listing.body['campaigns'];if(rows is! List||rows.length>100)throw const CnFailure('invalid_response');
   final counts=<String,int>{};for(final r in rows){if(r is Map&&r['campaignId'] is String)counts[r['campaignId']]=(counts[r['campaignId']]??0)+1;}
   final dup=counts.keys.where((k)=>counts[k]!>1).toSet(),out=<Map<String,dynamic>>[];
   for(final raw in rows){if(raw is! Map){out.add({'campaignId':'','outcome':'skipped','reason':'invalid_activity'});continue;}final r=raw;final id=r['campaignId'];String? skip=_skip(r,dup);
    if(r['uid']!=null&&r['uid']!=uid)skip='identity_mismatch';
    final server=listing.serverMs==null?null:listing.serverMs!+elapsed.elapsedMilliseconds;if(r['startAt']!=null||r['endAt']!=null){if(server==null)skip='server_time_required';else if(r['startAt'] is int&&server<r['startAt']*1000)skip='not_started';else if(r['endAt'] is int&&server>=r['endAt']*1000)skip='ended';}
    final key=jsonEncode([uid,id]);final old=s.data['claims'][key];
    final target={for(final k in ['campaignId','campaignKey','startAt','endAt'])k:r[k]};
    if(old!=null){
     final same=old['target'] is Map&&['campaignId','campaignKey','startAt','endAt'].every((k)=>old['target'][k]==target[k]);
     if(old['state']=='pending'||old['state']=='unknown'){
      if(same&&skip==null&&r['claimStatus']=='CLAIMED'){old['state']='reconciled';await _save(s);out.add({'campaignId':id,'outcome':'observedClaimed','reason':'reconciled_no_new_round'});}
      else{out.add({'campaignId':id,'outcome':'unknown','reason':'existing_attempt'});}continue;
     }
     if(same&&skip==null&&r['claimStatus']=='CLAIMED'){
      if(old['state']=='claimed'&&old['generation']==a['generation']){old['listingClaimed']=true;await _save(s);}
      out.add({'campaignId':id,'outcome':'observedClaimed'});continue;
     }
     final before=old['target'];final advanced=before is Map&&before['startAt'] is int&&before['endAt'] is int&&r['startAt'] is int&&r['endAt'] is int&&r['startAt']>=before['endAt'];
     final observedRearm=same&&old['state']=='claimed'&&old['listingClaimed']==true&&old['generation']==a['generation'];
     if(!advanced&&!observedRearm){out.add({'campaignId':id,'outcome':'skipped','reason':'same_campaign_no_new_window'});continue;}
    }
    if(skip!=null||r['claimStatus']!='CLAIMABLE'){out.add({'campaignId':id is String?id:'','outcome':r['claimStatus']=='CLAIMED'?'observedClaimed':'skipped','reason':skip??'not_claimable'});continue;}
    if(a['expiresAt']<=_now())throw const CnFailure('identity_expired');
    s.data['claims'][key]={'state':'pending','target':target,'generation':a['generation'],'listingClaimed':false};await _save(s); // Durable CAS BEFORE POST.
    final current=await _read();
    if(current.revision!=s.revision||current.data['accounts'][uid]?['generation']!=a['generation'])throw const CnFailure('source_changed');
    if(_now()<0||a['expiresAt']<=_now())throw const CnFailure('identity_expired');
    final dispatchServer=listing.serverMs==null?null:listing.serverMs!+elapsed.elapsedMilliseconds;
    if(r['startAt']!=null||r['endAt']!=null){if(dispatchServer==null||r['startAt'] is int&&dispatchServer<r['startAt']*1000||r['endAt'] is int&&dispatchServer>=r['endAt']*1000)throw const CnFailure('campaign_window_changed');}

    String outcome='unknown';
    try{
     final response=await _http.send('POST',Uri(scheme:'https',host:'openapi.qoder.com.cn',pathSegments:['sash','api','v1','me','campaigns',id,'claim']),a['token'],{});
     if(response.status!=200)throw const CnFailure('http_error');_envelope(response.body,uid,receipt:true);
     final data=response.body['data'];if(data!=null&&data is! Map)throw const CnFailure('invalid_response');
     for(final b in [response.body,if(data is Map)data]){_envelope(b,uid,receipt:true);for(final k in ['campaignId','campaignKey','startAt','endAt']){if(b[k]!=null&&r[k]!=null&&b[k]!=r[k])throw const CnFailure('invalid_response');}}
     if(response.body['status']=='CLAIMED'||data is Map&&data['status']=='CLAIMED')outcome='claimedDeltaUnknown';
    }catch(_){/* Never leak token-bearing transport errors or retry a POST. */}
    s.data['claims'][key]['state']=outcome=='unknown'?'unknown':'claimed';await _save(s);
    out.add({'campaignId':id,'outcome':outcome});
   }
   return List.unmodifiable(out);
  }on CnFailure{rethrow;}catch(_){throw const CnFailure('request_failed');}finally{_claiming=false;}
 }
}
