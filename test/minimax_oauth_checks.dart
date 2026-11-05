import '../lib/minimax_oauth.dart';
import '../lib/minimax_http.dart';

class FakeHttp extends MiniMaxHttp {
  int polls = 0;
  String? region, challenge;
  bool wrongRegion = false;
  @override
  Future<MiniMaxReply> oauth(
    String path,
    String selected,
    Map<String, String> body, {
    bool Function()? isCurrent,
  }) async {
    region = selected;
    if (path.endsWith('/code')) {
      challenge = body['code_challenge'];
      return MiniMaxReply(200, {
        'user_code': 'synthetic-user-code',
        'device_code': 'synthetic-device',
        'expires_in': 300,
        'interval': 1,
        'verification_uri_complete':
            'https://account.minimax.${wrongRegion ? 'io' : 'cn'}/login',
      });
    }
    polls++;
    if (polls == 1)
      return const MiniMaxReply(400, {'error': 'authorization_pending'});
    return const MiniMaxReply(200, {
      'access_token': 'synthetic-token',
      'refresh_token': 'synthetic-refresh',
      'token_type': 'Bearer',
      'scope': 'agent.default',
      'expires_in': 3600,
    });
  }
}

Future<void> main() async {
  var now = 100000;
  final http = FakeHttp(), auth = MiniMaxOAuth(region: 'cn', http: FakeHttp());
  auth.cancel();
  final flow = MiniMaxOAuth(region: 'cn', http: http, nowMs: () => now);
  final uri = await flow.begin();
  if (uri.host != 'account.minimax.cn' || http.challenge?.length != 43)
    throw StateError('PKCE/region');
  if (await flow.poll() != null) throw StateError('pending');
  now += 1000;
  final token = await flow.poll();
  if (token == null || token.expiresAtMs != 3701000)
    throw StateError('token expiry');
  await flow.poll();
  if (http.polls != 2) throw StateError('consumed device grant repeated');
  flow.cancel();
  final other = MiniMaxOAuth(
    region: 'cn',
    http: FakeHttp()..wrongRegion = true,
  );
  try {
    await other.begin();
    throw StateError('wrong region accepted');
  } on MiniMaxOAuthFailure {}
  print('PASS MiniMax PKCE, regions, pending, token retention, expiry');
}
