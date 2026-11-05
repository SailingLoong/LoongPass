import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../lib/minimax_http.dart';
void check(bool ok, String name) { if (!ok) throw StateError(name); }
Future<void> main() async {
  for (final pair in <String,String>{'':'d41d8cd98f00b204e9800998ecf8427e','a':'0cc175b9c0f1b6a831c399e269772661','abc':'900150983cd24fb0d6963f7d28e17f72','message digest':'f96b697d7cb7938d525a2f31aaf161d0','abcdefghijklmnopqrstuvwxyz':'c3fcd3d76192e4007dfb496cca67e13b','ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789':'d174ab98d277d9f5a5611c2c9f419d9f','1234567890'*8:'57edf4a22be3c955ac49da2e2107b67a'}.entries) {
    check(miniMaxWireMd5(pair.key)==pair.value,'MD5 standard vector');
  }
  final fixtures=jsonDecode(File('evidence/http-fixtures.json').readAsStringSync()) as List;
  for (final f in fixtures) {
    final endpoint=MiniMaxEndpoint.values.byName(f['endpoint']);
    final r=buildMiniMaxRequest(endpoint,accessToken:'synthetic-access',region:f['region'],userId:"user +!'()~中文",nowMilliseconds:1790000000000,timezoneOffsetSeconds:28800,os:'linux',version:"test +!'()~");
    check(r.uri.query==f['query'],'exact form query');
    check(r.headers['yy']==f['yy'],'exact yy');
    check(r.headers['x-signature']==f['signature'],'exact signature');
    check(r.headers['x-timestamp']=='1790000000','timestamp');
    check(r.headers['authorization']=='Bearer synthetic-access','bearer');
    check(r.uri.host==(f['region']=='cn'?'agent.minimaxi.com':'agent.minimax.io'),'origin');
    check(r.method==(endpoint==MiniMaxEndpoint.claim?'POST':'GET'),'method');
    check(r.body==(endpoint==MiniMaxEndpoint.claim?'{}':null),'body');
    check(!r.toString().contains('synthetic-access')&&!r.toString().contains('user +'),'request redaction');
  }
  for (final bad in ['', 'bad\r\nheader', 'a'*16385]) {
    try {buildMiniMaxRequest(MiniMaxEndpoint.profile,accessToken:bad,region:'cn'); throw StateError('accepted token');} on MiniMaxHttpException catch(e) {check(!e.toString().contains(bad)||bad.isEmpty,'error redaction');}
  }
  for (final region in ['CN','https://evil.test','']) {
    try {buildMiniMaxRequest(MiniMaxEndpoint.profile,accessToken:'a',region:region); throw StateError('accepted region');} on MiniMaxHttpException {}
  }
  for (final uid in [null,'','x\n','x'*257]) {
    try {buildMiniMaxRequest(MiniMaxEndpoint.claim,accessToken:'a',region:'cn',userId:uid); throw StateError('accepted user');} on MiniMaxHttpException {}
  }
  final good=_Client(200,'{"data":{"ok":true}}');
  final reply=await MiniMaxHttp(clientFactory:()=>good).send(MiniMaxEndpoint.claim,accessToken:'secret-token',region:'cn',userId:'user');
  check(reply.body?['data']['ok']==true&&reply.status==200,'JSON response');
  check(good.calls==1&&good.closed&&good.request.followRedirects==false&&good.request.maxRedirects==0,'single request no redirects closes client');
  check(utf8.decode(good.request.sent)=='{}','claim sends exact body');
  final nonJson=_Client(401,'sensitive raw error');
  check((await MiniMaxHttp(clientFactory:()=>nonJson).send(MiniMaxEndpoint.profile,accessToken:'a',region:'cn')).body==null,'preserve non-JSON auth status');
  final redirect=_Client(302,'redirect');
  check((await MiniMaxHttp(clientFactory:()=>redirect).send(MiniMaxEndpoint.claim,accessToken:'a',region:'cn',userId:'u')).status==302&&redirect.calls==1,'no redirect/replay');
  for(final c in [_Client(200,'invalid secret'),_Client(200,'[]'),_Client(200,'x'*30),_Client(200,'x'*30,unknownLength:true)]) {
    try {await MiniMaxHttp(clientFactory:()=>c,maxResponseBytes:20).send(MiniMaxEndpoint.profile,accessToken:'a',region:'cn');throw StateError('accepted invalid response');}
    on MiniMaxHttpException catch(e) {check(e.code=='invalid_response'&&c.closed,'bounded invalid response');}
  }
  final timeoutClient=_Client(200,'{}',hang:true);
  try {await MiniMaxHttp(clientFactory:()=>timeoutClient,timeout:Duration(milliseconds:5)).send(MiniMaxEndpoint.claim,accessToken:'a',region:'cn',userId:'u');throw StateError('missing timeout');}
  on MiniMaxHttpException catch(e) {check(e.code=='network_unavailable'&&timeoutClient.calls==1&&timeoutClient.closed,'timeout without retry');}
  var current=true;
  final delayed=_Client(200,'{}',delayOpen:true);
  final cancelled=MiniMaxHttp(clientFactory:()=>delayed).send(MiniMaxEndpoint.claim,accessToken:'old-secret',region:'cn',userId:'u',isCurrent:()=>current);
  current=false;
  delayed.openGate.complete(delayed.request);
  try {await cancelled;throw StateError('sent stale credentials');}
  on MiniMaxHttpException catch(e) {check(e.code=='request_cancelled'&&delayed.closed&&delayed.request.sent.isEmpty&&delayed.request.closeCalls==0&&(delayed.request.headers as _Headers).values.isEmpty,'cancelled after open before credential/body send');}
  final alreadyCancelled=_Client(200,'{}');
  try {await MiniMaxHttp(clientFactory:()=>alreadyCancelled).send(MiniMaxEndpoint.profile,accessToken:'old-secret',region:'cn',isCurrent:()=>false);throw StateError('opened stale request');}
  on MiniMaxHttpException catch(e) {check(e.code=='request_cancelled'&&alreadyCancelled.calls==0&&alreadyCancelled.closed,'cancelled before open');}
  print('PASS: MiniMax HTTP MD5, six independent wire fixtures, validation, redaction, response limits, timeout, no replay and stale-session cancellation');
}

class _Client implements HttpClient {
  final int status;
  final String body;
  final bool unknownLength,hang,delayOpen;
  final openGate=Completer<HttpClientRequest>();
  int calls=0;
  bool closed=false;
  late final _Request request=_Request(status,body,unknownLength);
  _Client(this.status,this.body,{this.unknownLength=false,this.hang=false,this.delayOpen=false});
  @override set connectionTimeout(Duration? value) {}
  @override set autoUncompress(bool value) {}
  @override Future<HttpClientRequest> openUrl(String method,Uri uri) async {calls++;if(delayOpen)return openGate.future;if(hang)return Completer<HttpClientRequest>().future;return request;}
  @override void close({bool force=false}) {closed=true;}
  @override dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class _Headers implements HttpHeaders {
  final values=<String,Object>{};
  @override void set(String name,Object value,{bool preserveHeaderCase=false}) {values[name]=value;}
  @override dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class _Request implements HttpClientRequest {
  final int status;
  final String body;
  final bool unknownLength;
  _Request(this.status,this.body,this.unknownLength);
  @override bool followRedirects=true;
  @override int maxRedirects=5;
  @override bool persistentConnection=true;
  @override final HttpHeaders headers=_Headers();
  final sent=<int>[];
  int closeCalls=0;
  @override void add(List<int> bytes) {sent.addAll(bytes);}
  @override Future<HttpClientResponse> close() async {closeCalls++;return _Response(status,body,unknownLength);}
  @override dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class _Response extends Stream<List<int>> implements HttpClientResponse {
  @override final int statusCode;
  final String body;
  final bool unknownLength;
  _Response(this.statusCode,this.body,this.unknownLength);
  @override int get contentLength=>unknownLength?-1:utf8.encode(body).length;
  @override StreamSubscription<List<int>> listen(void Function(List<int>)? onData,{Function? onError,void Function()? onDone,bool? cancelOnError})=>Stream<List<int>>.fromIterable(utf8.encode(body).map((b)=>[b])).listen(onData,onError:onError,onDone:onDone,cancelOnError:cancelOnError);
  @override dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
