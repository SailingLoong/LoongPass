import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/account_workspace_registry.dart';
import '../lib/compact_accounts_table.dart';
import '../lib/managed_app.dart';
import '../lib/workspace_accounts.dart';
import '../lib/claim_receipt.dart';

void main() {
  testWidgets(
    'overview retains a known expiry when the remaining amount is unknown',
    (tester) async {
      final registry = AccountWorkspaceRegistry();
      addTearDown(registry.dispose);
      registry.publish(ManagedApp.zcode, Object(), [
        AccountTableEntry(
          id: 'expiry',
          label: 'Known date',
          identity: 'synthetic',
          balance: '未知',
          status: 'ready',
          expiryAt: DateTime.now().add(const Duration(days: 1)),
          details: const Text('Details'),
        ),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkspaceOverviewPage(
              registry: registry,
              onOpenApp: (_) {},
              onOpenModels: () {},
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('额度未知'), findsOneWidget);
    },
  );
  testWidgets(
    'aggregate rows follow owner presentation and isolate identical regional IDs',
    (tester) async {
      final registry = AccountWorkspaceRegistry();
      final source = ValueNotifier('880 积分');
      var operations = 0;
      addTearDown(registry.dispose);
      addTearDown(source.dispose);
      Widget platform(ManagedApp app, String label) => AccountPresentationScope(
        app: app,
        registry: registry,
        child: ValueListenableBuilder<String>(
          valueListenable: source,
          builder: (context, balance, _) => CompactAccountsTable(
            entries: [
              AccountTableEntry(
                id: 'same-id',
                label: label,
                identity: 'synthetic',
                balance: balance,
                status: 'ready',
                onActivate: () => operations++,
                details: const Text('Details'),
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Offstage(child: platform(ManagedApp.qoderCn, 'CN account')),
                Offstage(child: platform(ManagedApp.qoder, 'Global account')),
                WorkspaceAccountsPage(registry: registry),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('account-qoderCn/same-id')), findsOneWidget);
      expect(find.byKey(const Key('account-qoder/same-id')), findsOneWidget);
      expect(find.text('880 积分'), findsNWidgets(2));
      source.value = '940 积分';
      await tester.pumpAndSettle();
      expect(find.text('880 积分'), findsNothing);
      expect(find.text('940 积分'), findsNWidgets(2));
      expect(operations, 0);
      await tester.tap(find.byKey(const Key('account-qoderCn/same-id')));
      await tester.pumpAndSettle();
      expect(find.text('Details'), findsOneWidget);
      expect(operations, 0);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'activity only shows confirmed receipts, with unknown amounts still unknown',
    (tester) async {
      final registry = AccountWorkspaceRegistry();
      addTearDown(registry.dispose);
      registry.publish(ManagedApp.zcode, Object(), const [
        AccountTableEntry(
          id: 'unknown',
          label: 'Pending',
          identity: 'synthetic',
          balance: '500000000 token',
          status: 'pending',
          needsAttention: true,
          details: Text('Pending details'),
        ),
        AccountTableEntry(
          id: 'confirmed',
          label: 'Confirmed',
          identity: 'synthetic',
          balance: '500000000 token',
          status: 'ready',
          receipt: ClaimReceipt(),
          details: Text('Confirmed details'),
        ),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkspaceActivityPage(registry: registry, onOpenApp: (_) {}),
          ),
        ),
      );
      expect(find.textContaining('Confirmed'), findsOneWidget);
      expect(find.textContaining('金额未知'), findsOneWidget);
      expect(find.textContaining('500000000'), findsNothing);
      expect(find.textContaining('Pending'), findsNothing);
      await tester.tap(find.text('待处理'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Pending'), findsOneWidget);
      expect(find.textContaining('Confirmed'), findsNothing);
    },
  );
}
