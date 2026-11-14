import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/app_sidebar.dart';
import '../lib/account_workspace_registry.dart';
import '../lib/compact_accounts_table.dart';
import '../lib/workspace_accounts.dart';
import 'desktop_test_app.dart';

void main() {
  testDesktopWidgets('overview keeps account service recovery visible', (
    tester,
  ) async {
    final registry = AccountWorkspaceRegistry();
    addTearDown(registry.dispose);
    var retries = 0;
    await tester.pumpWidget(
      DesktopTestApp(
        home: Scaffold(
          body: WorkspaceOverviewPage(
            registry: registry,
            onOpenApp: (_) {},
            serviceStatus: TextButton(
              onPressed: () => retries++,
              child: const Text('服务启动失败，重试'),
            ),
          ),
        ),
      ),
    );
    expect(find.text('从第一个账号开始'), findsNothing);
    await tester.tap(find.text('服务启动失败，重试'));
    expect(retries, 1);
  });

  testDesktopWidgets('empty and single-page lists omit irrelevant controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      const DesktopTestApp(
        home: Scaffold(body: CompactAccountsTable(entries: [])),
      ),
    );
    expect(find.byKey(const Key('account-search')), findsNothing);
    expect(find.byKey(const Key('account-page-size')), findsNothing);
    var activations = 0;
    await tester.pumpWidget(
      DesktopTestApp(
        home: Scaffold(
          body: CompactAccountsTable(
            entries: [
              AccountTableEntry(
                id: 'one',
                label: 'Demo',
                identity: 'demo@example.test',
                balance: '3899.96 credits',
                status: '需要重新授权',
                needsAttention: true,
                observedAt: DateTime(2026, 11, 14, 9, 30),
                onActivate: () => activations++,
                details: const Text('Details'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('需要重新授权').hitTestable(), findsOneWidget);
    final balance = find.byKey(const Key('balance-one'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(balance));
    await tester.pump(
      tester.element(balance).theme.tooltipStyle.hoverEnterDuration,
    );
    await tester.pumpAndSettle();
    expect(
      find.text('2026-11-14 09:30 查询 · 查看账号详情').hitTestable(),
      findsOneWidget,
    );
    expect(activations, 0);
    await mouse.moveTo(Offset.zero);
    await mouse.removePointer();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account-page-size')), findsNothing);
    await tester.tap(find.byKey(const Key('activate-one')).hitTestable());
    await tester.pumpAndSettle();
    expect(activations, 1);
  });

  testDesktopWidgets(
    'overview opens the exact live account without losing context',
    (tester) async {
      final registry = AccountWorkspaceRegistry();
      final source = Object();
      addTearDown(registry.dispose);
      AccountTableEntry entry(String id, String detail) => AccountTableEntry(
        id: id,
        label: id,
        identity: id,
        balance: '0 credits',
        status: '待核验',
        needsAttention: true,
        details: Text(detail),
      );
      registry.publish(ManagedApp.qoderCn, source, [
        entry('same', 'CN detail'),
      ]);
      registry.publish(ManagedApp.qoder, Object(), [
        entry('same', 'Global detail'),
      ]);
      var navigations = 0;
      await tester.pumpWidget(
        DesktopTestApp(
          home: Scaffold(
            body: WorkspaceOverviewPage(
              registry: registry,
              onOpenApp: (_) => navigations++,
            ),
          ),
        ),
      );
      final cnAccount = find.ancestor(
        of: find.text('Qoder CN · 待核验'),
        matching: find.byType(FItem),
      );
      final globalAccount = find.ancestor(
        of: find.text('Qoder · 待核验'),
        matching: find.byType(FItem),
      );
      expect(cnAccount, findsOneWidget);
      expect(globalAccount, findsOneWidget);
      await tester.tap(
        find.descendant(of: cnAccount, matching: find.text('same')),
      );
      await tester.pumpAndSettle();
      expect(find.text('CN detail'), findsOneWidget);
      expect(find.text('Global detail'), findsNothing);
      expect(navigations, 0);
      registry.publish(ManagedApp.qoderCn, source, [
        entry('same', 'Updated CN detail'),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Updated CN detail'), findsOneWidget);
      registry.remove(ManagedApp.qoderCn, source);
      await tester.pumpAndSettle();
      expect(find.text('账号已移除'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('总览'), findsOneWidget);
      await tester.tap(
        find.descendant(of: globalAccount, matching: find.text('same')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Global detail'), findsOneWidget);
      expect(find.text('Updated CN detail'), findsNothing);
      expect(navigations, 0);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
    },
  );

  testDesktopWidgets(
    'task navigation retains platform scope and unfinished input',
    (tester) async {
      final workspace = GlobalKey<AppWorkspaceState>();
      await tester.pumpWidget(
        DesktopTestApp(
          home: Scaffold(
            body: AppWorkspace(
              key: workspace,
              pages: const {ManagedApp.qoder: TextField(key: Key('draft'))},
              sections: const {
                WorkspaceSection.accounts: Text('All accounts'),
                WorkspaceSection.models: Text('Models'),
              },
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('app-order')), findsNothing);
      expect(find.byKey(const Key('account-apps')), findsOneWidget);
      expect(find.byKey(const Key('platform-filter')), findsNothing);
      workspace.currentState!.selectApp(ManagedApp.qoder);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('draft')), 'keep this');
      await tester.ensureVisible(find.byKey(const Key('nav-models')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-models')));
      await tester.pumpAndSettle();
      expect(find.text('Models'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('nav-accounts')),
        -200,
        scrollable: find.descendant(
          of: find.byKey(const Key('app-sidebar')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-accounts')));
      await tester.pumpAndSettle();
      expect(find.text('keep this'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
