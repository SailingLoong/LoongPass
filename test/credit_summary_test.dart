import 'package:flutter_test/flutter_test.dart';
import '../lib/account_table_entry.dart';

void main() {
  test(
    'credit formatting removes floating point noise and retains precision',
    () {
      expect(accountPoints(0.1 + 0.2), '0.3');
      expect(accountPoints(4321.5678), '4321.5678');
    },
  );
}
