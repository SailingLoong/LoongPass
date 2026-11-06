// The real widget and activity protocol are exercised by test/zcode_panel_test.dart
// and test/zcode_activities_checks.dart. Keep the native-switch gate independent.
import 'dart:io';

void main() {
  final root = Platform.script.resolve('../');
  final gate = File.fromUri(
    root.resolve('lib/native_account_gate.dart'),
  ).readAsStringSync();
  if (!gate.contains('const zcodeNativeAdapterValidated = false;')) {
    throw StateError('Native switching needs separate real-client acceptance');
  }
  print('PASS ZCode native switching remains independently gated');
}
