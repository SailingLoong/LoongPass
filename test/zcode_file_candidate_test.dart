import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/zcode_auth_file.dart';
import '../lib/zcode_accounts.dart';

Map<String, String> syntheticZcode({
  String family = 'zai',
  String id = 'synthetic-id',
}) => {
  'oauth:active_provider': 'SYNTHETIC_PROVIDER',
  'oauth:$family:access_token': 'SYNTHETIC_ACCESS',
  'oauth:$family:user_info': 'SYNTHETIC_USER_INFO',
  'oauth:$family:refresh_token': 'SYNTHETIC_REFRESH',
  'zcodejwttoken': 'SYNTHETIC_JWT',
  'account-provider:coding-plan:account:$family-individual-coding-plan:account:$id:api-key':
      'SYNTHETIC_KEY',
  'unrelated': 'SYNTHETIC_UNRELATED',
};
void main() {
  late Directory temp;
  late File file;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('loongpass-zcode-candidate-');
    file = File('${temp.path}/saved.json');
  });
  tearDown(() async => temp.delete(recursive: true));
  test(
    'candidate inspects supported fields without trusting or exposing a user identity',
    () async {
      final input = syntheticZcode();
      await file.writeAsString(jsonEncode(input));
      final candidate = await ZcodeAuthFile.inspectForImport(file);
      expect(candidate.families, {'zai'});
      expect(candidate.toString(), 'ZcodeFileCandidate(unverified)');
      expect(() => candidate.families.add('other'), throwsUnsupportedError);
      expect(jsonDecode(await file.readAsString()), input);
    },
  );
  test(
    'both supported families can remain opaque without choosing a fake active account',
    () async {
      await file.writeAsString(
        jsonEncode({
          ...syntheticZcode(),
          ...syntheticZcode(family: 'bigmodel'),
        }),
      );
      expect((await ZcodeAuthFile.inspectForImport(file)).families, {
        'zai',
        'bigmodel',
      });
    },
  );
  test(
    'missing or empty required session fields cannot become importable candidates',
    () async {
      for (final data in [
        {'other': 'SYNTHETIC'},
        {...syntheticZcode(), 'oauth:active_provider': ''},
        {...syntheticZcode(), 'oauth:zai:access_token': ''},
        {...syntheticZcode(), 'oauth:zai:user_info': ''},
      ]) {
        await file.writeAsString(jsonEncode(data));
        await expectLater(
          ZcodeAuthFile.inspectForImport(file),
          throwsA(
            isA<AccountFailure>().having(
              (e) => e.code,
              'code',
              'MissingSessionCredential',
            ),
          ),
        );
      }
    },
  );
  test(
    'only an explicit verified-identity boundary invokes the existing snapshot import',
    () async {
      final input = syntheticZcode();
      await file.writeAsString(jsonEncode(input));
      final candidate = await ZcodeAuthFile.inspectForImport(file);
      // The identity is explicitly synthetic test evidence, not derived from the file.
      final identity = AccountIdentity(
        'synthetic-test-context',
        'zai',
        'synthetic-id',
      );
      final snapshot = await candidate.snapshotFor(identity);
      final plan = SwitchPlan.prepare(identity, input, snapshot);
      expect(plan.isNoop, true);
      expect(plan.apply(input), input);
    },
  );
  test(
    'snapshot import rereads saved bytes and refuses changed invalid contents',
    () async {
      await file.writeAsString(jsonEncode(syntheticZcode()));
      final candidate = await ZcodeAuthFile.inspectForImport(file);
      await file.writeAsString('{"SYNTHETIC_SECRET":42}');
      await expectLater(
        candidate.snapshotFor(
          AccountIdentity('synthetic', 'zai', 'synthetic-id'),
        ),
        throwsA(
          isA<AccountFailure>().having(
            (e) => e.code,
            'code',
            'InvalidDocument',
          ),
        ),
      );
    },
  );
}
