import 'package:flutter_test/flutter_test.dart';
import '../lib/rewards/reward_provider.dart';
import '../lib/rewards/reward_transport.dart';

void main() {
  test(
    'credential-bearing requests reject untrusted origins before opening a connection',
    () async {
      final http = RewardHttp({'api.example.test'});
      addTearDown(http.close);
      for (final url in [
        'http://api.example.test/balance',
        'https://evil.example.test/balance',
        'https://api.example.test:8443/balance',
        'https://user:password@api.example.test/balance',
        'https://api.example.test/balance#token',
      ]) {
        await expectLater(
          http.send(
            'GET',
            Uri.parse(url),
            headers: {'Authorization': 'Bearer synthetic'},
          ),
          throwsA(
            isA<RewardFailure>().having(
              (e) => e.code,
              'code',
              'invalid_endpoint',
            ),
          ),
        );
      }
    },
  );
}
