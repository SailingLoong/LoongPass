// Synthetic credentials only.
import 'dart:convert';
import 'dart:typed_data';
enum MiniMaxRegion {cn, global}
const home = '/fixture/.minimax/auth';
const accountKey = '7S9GzXfrtrXVItOn_bFkkswkQJUGv24VeAoXTI6-br8';
String path(MiniMaxRegion region) => '$home/prod/${region == MiniMaxRegion.cn ? 'cn' : 'en'}/mcode-public/auth.json';
String key(MiniMaxRegion r) => 'com.minimax.mcode.oauth.prod.${r == MiniMaxRegion.cn ? 'cn' : 'en'}\u0000$accountKey';
Map<String,Object?> record() => {'schemaVersion':1,'accessToken':'synthetic-access','refreshToken':'synthetic-refresh','clientId':'mcode-public','tokenType':'Bearer','audience':'agent-backend','scopes':['agent.default'],'expiresAtMs':1000000,'generation':9,'subject':'synthetic-local-subject','accountId':'synthetic-billing-id','loginEpoch':'synthetic-epoch'};
Uint8List bytes({MiniMaxRegion region = MiniMaxRegion.cn, Map<String,Object?>? row, Map<String,Object?>? document}) => Uint8List.fromList(utf8.encode(jsonEncode(document ?? {'schemaVersion':1,'records':{key(region):row ?? record()}})));
