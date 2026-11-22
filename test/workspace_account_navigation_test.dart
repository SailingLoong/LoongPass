import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import '../lib/main.dart';
import '../lib/plugin_accounts.dart';
import 'desktop_test_app.dart';
import 'model_workspace_fixture.dart';

void main() {
  testDesktopWidgets(
    'saved accounts remain accessible while balances are loading',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1080, 748);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final app = ModelWorkspaceFixture();
      addTearDown(app.dispose);
      final saved = app.accounts.accounts.first;
      app.accounts.catalogReady = false;
      app.accounts.accounts
        ..clear()
        ..add(
          PluginAccount(
            key: saved.key,
            facts: saved.facts,
            active: true,
            models: [],
          ),
        );
      await tester.pumpWidget(AccountToolApp(application: app));
      await tester.pumpAndSettle();
      expect(find.text('正在刷新模型与额度…').hitTestable(), findsOneWidget);
      await tester.tap(find.byKey(const Key('nav-accounts')));
      await tester.pumpAndSettle();
      expect(find.text(saved.label).hitTestable(), findsOneWidget);
      expect(find.text('无可用模型').hitTestable(), findsNothing);
      expect(find.text('需要重新授权').hitTestable(), findsNothing);
      app.models.completeCatalog();
      await tester.pumpAndSettle();
      expect(find.text('正在刷新模型与额度…').hitTestable(), findsNothing);
      expect(find.text('无可用模型').hitTestable(), findsOneWidget);
    },
  );

  Future<void> openAccounts(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1080, 748);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final app = ModelWorkspaceFixture();
    addTearDown(app.dispose);
    await tester.pumpWidget(AccountToolApp(application: app));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-accounts')));
    await tester.pumpAndSettle();
  }

  testDesktopWidgets(
    'balance tooltip leaves the accessibility tree with the account list',
    (tester) async {
      await openAccounts(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      addTearDown(mouse.removePointer);
      final balance = find.byKey(const Key('balance-qoderCn/saved-0'));
      await mouse.moveTo(tester.getCenter(balance));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.textContaining('查看账号详情'), findsOneWidget);
      _expectAttachedOverlayAnchors(tester);

      final target = tester.getCenter(find.byKey(const Key('nav-models')));
      await mouse.moveTo(target);
      await mouse.down(target);
      await mouse.up();
      await tester.pump();
      expect(
        find.byKey(const Key('model-search')).hitTestable(),
        findsOneWidget,
      );
      _expectAttachedOverlayAnchors(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testDesktopWidgets(
    'the sort menu has its own accessibility anchor next to the filter menu',
    (tester) async {
      await openAccounts(tester);
      await tester.tap(find.byKey(const Key('account-sort')));
      await tester.pumpAndSettle();
      expect(find.text('名称升序').hitTestable(), findsOneWidget);
      _expectAttachedOverlayAnchors(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testDesktopWidgets(
    'workspace destinations browse without authorization; the selected add-account target starts once',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1080, 748);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      const channel = MethodChannel('com.sailingloong.loongpass/files');
      final messenger = tester.binding.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return {
          'available': true,
          'accounts': [],
          'loginPending': false,
          'busy': false,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final app = ModelWorkspaceFixture();
      addTearDown(app.dispose);
      await tester.pumpWidget(AccountToolApp(application: app));
      await tester.pumpAndSettle();
      Future<void> click(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      final overview = find.byKey(const Key('nav-overview'));
      await click(overview);
      await click(find.byKey(const Key('nav-activity')));
      await click(find.text('最近领取 0'));
      expect(find.text('暂无已确认的领取记录。'), findsOneWidget);
      await click(find.byKey(const Key('nav-accounts')));
      expect(find.byKey(const Key('section-accounts')), findsOneWidget);
      await click(find.text('添加账号'));
      expect(calls.where((c) => c != 'codexAccountsStatus'), isEmpty);
      final platform = find.descendant(
        of: find.byType(FDialog),
        matching: find.text('Codex'),
      );
      await click(platform);
      expect(find.byKey(const Key('page-codex')), findsOneWidget);
      expect(calls.where((c) => c != 'codexAccountsStatus'), [
        'codexStartLogin',
      ]);
      expect(app.accounts.refreshes, 0);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}

void _expectAttachedOverlayAnchors(WidgetTester tester) {
  final anchors = <Object>{};
  final overlays = <Object>{};
  bool visit(SemanticsNode node) {
    if (!node.isMergedIntoParent) {
      final data = node.getSemanticsData();
      if (data.traversalParentIdentifier case final id?) anchors.add(id);
      if (data.traversalChildIdentifier case final id?) overlays.add(id);
    }
    node.visitChildren(visit);
    return true;
  }

  visit(
    tester.binding.renderViews.single.owner!.semanticsOwner!.rootSemanticsNode!,
  );
  expect(
    overlays.difference(anchors),
    isEmpty,
    reason: 'Every exposed overlay needs an attached accessibility anchor.',
  );
}
