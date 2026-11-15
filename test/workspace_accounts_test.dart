import 'desktop_test_app.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/account_workspace_registry.dart';
import '../lib/compact_accounts_table.dart';
import '../lib/managed_app.dart';
import '../lib/workspace_accounts.dart';
import '../lib/claim_receipt.dart';

void main() {
  testDesktopWidgets('account deep link reveals the exact paginated account', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final registry = AccountWorkspaceRegistry();
    final page = GlobalKey<WorkspaceAccountsPageState>();
    addTearDown(registry.dispose);
    var operations = 0;
    final source = Object();
    registry.publish(ManagedApp.qoderCn, source, [
      for (var i = 0; i < 15; i++)
        AccountTableEntry(
          id: '$i',
          label: 'Account $i',
          identity: 'synthetic',
          balance: '60 积分',
          status: 'ready',
          details: Text('Details $i'),
          onActivate: () => operations++,
        ),
    ]);
    registry.publish(ManagedApp.qoder, Object(), const [
      AccountTableEntry(
        id: '14',
        label: 'Global 14',
        identity: 'synthetic',
        balance: '90 积分',
        status: 'ready',
        details: Text('Global details'),
      ),
    ]);
    await tester.pumpWidget(
      DesktopTestApp(
        home: Scaffold(
          body: WorkspaceAccountsPage(key: page, registry: registry),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('account-search')), 'missing');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的账号。'), findsOneWidget);
    expect(page.currentState!.revealAccount('qoderCn/14'), isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account-qoderCn/14')), findsOneWidget);
    expect(find.text('Account 0'), findsNothing);
    final target = tester.getRect(find.byKey(const Key('account-qoderCn/14')));
    expect(target.top, greaterThanOrEqualTo(0));
    expect(target.bottom, lessThanOrEqualTo(600));
    expect(operations, 0);
    await tester.tap(find.byKey(const Key('account-qoderCn/14')));
    await tester.pumpAndSettle();
    expect(find.text('Details 14'), findsOneWidget);
    expect(find.text('Global details'), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(page.currentState!.revealAccount('qoderCn/0'), isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account-qoderCn/0')), findsOneWidget);
    expect(find.text('Account 14'), findsNothing);
    registry.publish(ManagedApp.qoderCn, source, []);
    await tester.pumpAndSettle();
    expect(page.currentState!.revealAccount('qoderCn/14'), isFalse);
    expect(operations, 0);
    expect(tester.takeException(), isNull);
  });
  testDesktopWidgets('overview makes every attention account reachable', (
    tester,
  ) async {
    final registry = AccountWorkspaceRegistry();
    addTearDown(registry.dispose);
    var operations = 0;
    registry.publish(ManagedApp.zcode, Object(), [
      for (var index = 1; index <= 6; index++)
        AccountTableEntry(
          id: '$index',
          label: 'Account $index',
          identity: 'synthetic-$index',
          balance: '880 积分',
          status: '需要重新授权后核对官方额度',
          statusLabel: '需要重新授权',
          needsAttention: true,
          onActivate: () => operations++,
          details: Text('Details $index'),
        ),
    ]);
    await tester.pumpWidget(
      DesktopTestApp(
        home: Scaffold(
          body: WorkspaceOverviewPage(registry: registry, onOpenApp: (_) {}),
        ),
      ),
    );
    expect(find.text('Account 6'), findsNothing);
    final showAll = find.byKey(const Key('overview-all-attention'));
    await tester.ensureVisible(showAll);
    await tester.tap(showAll);
    await tester.pumpAndSettle();
    expect(find.text('Account 6'), findsOneWidget);
    await tester.ensureVisible(find.text('Account 6'));
    await tester.tap(find.text('Account 6'));
    await tester.pumpAndSettle();
    expect(find.text('Details 6'), findsOneWidget);
    expect(operations, 0);
    expect(tester.takeException(), isNull);
  });

  testDesktopWidgets(
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
        DesktopTestApp(
          home: Scaffold(
            body: WorkspaceOverviewPage(registry: registry, onOpenApp: (_) {}),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('额度未知'), findsOneWidget);
    },
  );
  testDesktopWidgets(
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
        DesktopTestApp(
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
  testDesktopWidgets(
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
        DesktopTestApp(
          home: Scaffold(body: WorkspaceActivityPage(registry: registry)),
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
