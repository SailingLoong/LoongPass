import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/zcode_accounts_panel.dart';
import '../lib/zcode_activity_accounts.dart';
import '../lib/zcode_api.dart';
import 'memory_account_store.dart';
import 'zcode_activities_checks.dart' as fixture;

void main() {
  testWidgets(
    'restores activity accounts without consuming a reward during render',
    (tester) async {
      final store = MemoryAccountStore('panel');
      final http = fixture.FakeZcode();
      final previous = await fixture.account(store, http);
      previous.dispose();
      final owner = ZcodeActivityAccounts(
        store: store,
        api: ZcodeApi(http),
        now: () => fixture.now,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ZcodeAccountsPanel(create: () => owner),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Synthetic'), findsOneWidget);
      expect(find.text('授权智谱 BigModel 账号'), findsOneWidget);
      expect(find.textContaining('签到'), findsNothing);
      expect(find.textContaining('Z.AI'), findsNothing);
      expect(http.claims, 0);
      expect(http.balanceCalls, 0);
      await tester.tap(find.text('检查活动与额度'));
      await tester.pumpAndSettle();
      expect(find.text('当前有可领取活动，尚未领取。'), findsOneWidget);
      expect(http.claims, 0);
      await tester.tap(find.text('核对并领取活动'));
      await tester.pumpAndSettle();
      expect(find.text('已核对官方活动权益到账。'), findsOneWidget);
      expect(http.claims, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'unavailable native platform does not advertise successful switching',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: ZcodeAccountsPanel()),
          ),
        ),
      );
      expect(find.textContaining('切换成功'), findsNothing);
      expect(find.textContaining('本次内存'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
