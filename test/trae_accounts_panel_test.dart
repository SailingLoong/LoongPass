import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/trae_accounts.dart';
import '../lib/trae_accounts_panel.dart';
import 'memory_account_store.dart';
import 'trae_accounts_checks.dart' as fixtures;

void main() {
  testWidgets('an ineligible reward is distinct from an unchecked account', (
    tester,
  ) async {
    final http = fixtures.FakeTrae()..enabled = false;
    final owner = TraeAccounts(
      store: MemoryAccountStore('trae'),
      http: http,
      proof: (_, _) async => {'Signature': 'synthetic-proof'},
      now: () => fixtures.instant,
    );
    await owner.importCurrent(fixtures.context());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TraeAccountsPanel(create: () => owner)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('account-${(await owner.accounts()).first.uid}')),
    );
    await tester.pumpAndSettle();
    expect(find.text('等待签到检查。'), findsOneWidget);
    await tester.tap(find.text('核对并签到'));
    await tester.pumpAndSettle();
    expect(find.text('当前账号暂无可领取的签到奖励。'), findsOneWidget);
    expect(find.text('等待签到检查。'), findsNothing);
    expect(http.claims, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
