import 'package:flutter_test/flutter_test.dart';
import '../tool/zcode_accounts_checks.dart' as contract;

void main() {
  test('all 29 pure account contract checks pass', () {
    contract.main();
    expect(contract.failed, 0);
    expect(contract.passed, 29);
  });
}
