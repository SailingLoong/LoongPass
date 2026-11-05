// Text/route guard only. This does not compile, render, or test a Flutter widget.
import 'dart:io';

void check(bool condition, String label) {
  if (!condition) throw StateError(label);
}

void main() {
  final root = Platform.script.resolve('../');
  final panel = File.fromUri(root.resolve('lib/zcode_accounts_panel.dart')).readAsStringSync();
  final main = File.fromUri(root.resolve('lib/main.dart')).readAsStringSync();
  final gate = File.fromUri(root.resolve('lib/native_account_gate.dart')).readAsStringSync();
  check(panel.contains('半夜与周末活动') && !panel.contains('签到'),
      'ZCode vocabulary remains activities, not daily check-in');
  check(panel.contains('权益生效（UTC）') && panel.contains('权益到期（UTC）') &&
      panel.contains('以下为权益有效期，不代表活动开放窗口。') &&
      !panel.contains('服务端活动开始参考') && !panel.contains('服务端活动结束参考'),
      'entitlement validity is not an offer window');
  check(panel.contains('需要人工验证码，尚未接线，不会自动重发。'),
      'manual verification gap remains explicit');
  check(panel.contains('仍可检查活动预览核实，不会重发领取。'),
      'uncertain mutation lock retains an explicit read-only verification path');
  check(panel.contains('每 10 分钟检查服务端活动') &&
      panel.contains('本次会话自动检查并领取'), 'session-only activity polling copy');
  check(gate.contains('const zcodeNativeAdapterValidated = false;') &&
      panel.contains('nativeValidated: zcodeNativeAdapterValidated &&') &&
      main.contains('ZCode 凭证切换尚未接通。') && !main.contains('const ZcodeAccountsPanel()'),
      'ZCode route remains closed independently of other validated platforms');
  check(!main.contains('demo') && !main.contains('sample'), 'no production demo route');
  print('PASS ZCode panel static wording and production-route guards (not Flutter execution)');
}
