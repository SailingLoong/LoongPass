import 'desktop_test_app.dart';

import 'package:forui/forui.dart';

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/account_workspace_registry.dart';
import '../lib/app_theme.dart';
import '../lib/codex_accounts.dart';
import '../lib/codex_accounts_panel.dart';
import '../lib/managed_app.dart';

const _channel = MethodChannel('test.loongpass/codex-panel');
const _first = {
  'id': 'official-a',
  'email': 'same@example.invalid',
  'workspaceId': 'workspace-a',
  'plan': 'plus',
};
const _second = {
  'id': 'official-b',
  'email': 'same@example.invalid',
  'workspaceId': 'workspace-b',
  'plan': 'team',
};

Map<String, Object?> _snapshot({
  List<Map<String, String>> accounts = const [_first, _second],
  bool available = true,
  bool busy = false,
  bool loginPending = false,
  String? issue,
  String? outcome,
  String? message,
  String currentId = 'official-a',
}) => {
  'available': available,
  if (issue != null) 'issue': issue,
  'accounts': accounts,
  'currentId': currentId,
  'loginPending': loginPending,
  'busy': busy,
  'observedAt': '2026-11-07T08:15:00Z',
  if (outcome != null) 'outcome': outcome,
  if (message != null) 'message': message,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  CodexAccounts owner({TargetPlatform platform = TargetPlatform.macOS}) {
    final result = CodexAccounts(channel: _channel, platform: platform);
    addTearDown(result.dispose);
    return result;
  }

  Future<void> mount(
    WidgetTester tester,
    CodexAccounts accounts, {
    double width = 1280,
    AccountWorkspaceRegistry? registry,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final panel = CodexAccountsPanel(owner: accounts);
    await tester.pumpWidget(
      DesktopTestApp(
        theme: loongPassTheme(Brightness.light),
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              if (registry == null)
                panel
              else
                AccountPresentationScope(
                  app: ManagedApp.codex,
                  registry: registry,
                  child: panel,
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> details(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(Key('account-$id')));
    await tester.pumpAndSettle();
  }

  testDesktopWidgets(
    'rendering publishes safe account presentation without native mutations',
    (tester) async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call.method);
        return _snapshot();
      });
      final accounts = owner();
      await accounts.refreshSnapshot();
      final registry = AccountWorkspaceRegistry();
      addTearDown(registry.dispose);
      await mount(tester, accounts, registry: registry);
      expect(find.byKey(const Key('account-official-a')), findsOneWidget);
      expect(find.byKey(const Key('account-official-b')), findsOneWidget);
      expect(find.textContaining('本机登录记录'), findsWidgets);
      expect(
        registry.entriesFor(ManagedApp.codex).map((a) => a.identity),
        containsAll(['workspace-a', 'workspace-b']),
      );
      expect(
        registry
            .entriesFor(ManagedApp.codex)
            .every((a) => a.credits == null && a.receipt == null),
        isTrue,
      );
      expect(find.text('7 天内到期'), findsNothing);
      expect(find.text('余额'), findsNothing);
      expect(find.textContaining('plus'), findsOneWidget);
      await details(tester, 'official-a');
      expect(
        find.descendant(
          of: find.byType(FDialog),
          matching: find.textContaining('workspace-a'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(FDialog),
          matching: find.textContaining('plus'),
        ),
        findsOneWidget,
      );
      expect(find.text('最近一次成功领取'), findsNothing);
      expect(find.textContaining('切换成功'), findsNothing);
      expect(calls, ['codexAccountsStatus']);
    },
  );

  testDesktopWidgets('cancelled restart confirmation sends no activation', (
    tester,
  ) async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      return _snapshot();
    });
    final accounts = owner();
    await accounts.refreshSnapshot();
    await mount(tester, accounts);
    await details(tester, 'official-b');
    await tester.tap(find.byKey(const Key('codex-switch-official-b')));
    await tester.pumpAndSettle();
    expect(find.textContaining('正常退出'), findsOneWidget);
    expect(find.textContaining('项目、对话与设置'), findsOneWidget);
    await tester.tap(find.byKey(const Key('codex-confirm-cancel')));
    await tester.pumpAndSettle();
    expect(calls, ['codexAccountsStatus']);
  });

  for (final outcome in {
    'opened': '已重新打开 Codex',
    'applied': '登录记录已应用。打开 Codex',
    'unchanged': '本机登录记录与所选账号一致',
  }.entries) {
    testDesktopWidgets(
      'activation describes ${outcome.key} without verified identity claims',
      (tester) async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return _snapshot(
            currentId: call.method == 'codexActivate'
                ? 'official-b'
                : 'official-a',
            outcome: call.method == 'codexActivate' ? outcome.key : null,
          );
        });
        final accounts = owner();
        await accounts.refreshSnapshot();
        await mount(tester, accounts);
        await details(tester, 'official-b');
        await tester.tap(find.byKey(const Key('codex-switch-official-b')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('codex-confirm-switch')));
        await tester.pumpAndSettle();
        expect(calls.last.method, 'codexActivate');
        expect(calls.last.arguments, {'id': 'official-b'});
        expect(find.textContaining(outcome.value), findsWidgets);
        expect(find.textContaining('切换成功'), findsNothing);
        expect(find.textContaining('已核实'), findsNothing);
      },
    );
  }

  testDesktopWidgets(
    'import, official login, cancellation and saved-copy removal are explicit',
    (tester) async {
      var imported = false, pending = false;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'codexImportCurrent':
            imported = true;
          case 'codexStartLogin':
            pending = true;
          case 'codexCancelLogin':
            pending = false;
          case 'codexRemove':
            imported = false;
        }
        return _snapshot(
          accounts: imported ? [_first] : [],
          loginPending: pending,
        );
      });
      final accounts = owner();
      await accounts.refreshSnapshot();
      await mount(tester, accounts);
      expect(find.byKey(const Key('account-official-a')), findsNothing);
      await tester.tap(find.byKey(const Key('codex-import')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('account-official-a')), findsOneWidget);
      await tester.tap(find.byKey(const Key('codex-login')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<FButton>(find.byKey(const Key('codex-import'))).onPress,
        isNull,
      );
      await tester.tap(find.byKey(const Key('codex-cancel-login')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('codex-cancel-login')), findsNothing);
      await details(tester, 'official-a');
      await tester.tap(find.byKey(const Key('codex-remove-official-a')));
      await tester.pumpAndSettle();
      expect(find.textContaining('不会退出 Codex'), findsOneWidget);
      await tester.tap(find.byKey(const Key('codex-confirm-remove')));
      await tester.pumpAndSettle();
      expect(calls.map((c) => c.method), [
        'codexAccountsStatus',
        'codexImportCurrent',
        'codexStartLogin',
        'codexCancelLogin',
        'codexRemove',
      ]);
      expect(calls.last.arguments, {'id': 'official-a'});
      expect(find.text('账号已移除'), findsOneWidget);
    },
  );

  testDesktopWidgets(
    'native busy and failed operations disable conflicting controls without exposing diagnostics',
    (tester) async {
      final pending = Completer<Map<String, Object?>>();
      messenger.setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'codexImportCurrent') return pending.future;
        return _snapshot();
      });
      final accounts = owner();
      await accounts.refreshSnapshot();
      await mount(tester, accounts);
      await tester.tap(find.byKey(const Key('codex-import')));
      await tester.pump();
      expect(
        tester.widget<FButton>(find.byKey(const Key('codex-login'))).onPress,
        isNull,
      );
      expect(find.byType(FProgress), findsOneWidget);
      pending.completeError(
        PlatformException(
          code: 'synthetic-secret',
          message: 'synthetic-token',
          details: {'access_token': 'private'},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('结果未能确认'), findsOneWidget);
      expect(find.textContaining('synthetic'), findsNothing);
      expect(
        tester.widget<FButton>(find.byKey(const Key('codex-login'))).onPress,
        isNull,
      );
    },
  );

  for (final issue in {
    'runtimeUnavailable': '安装或更新 Codex 后重启 LoongPass',
    'unsupportedStore': '如自行调整了 Codex 的存储设置，请重启 LoongPass',
    'restricted': '登录或工作区限制',
    'unavailable': 'Codex 账号功能暂不可用',
  }.entries) {
    testDesktopWidgets(
      '${issue.key} disables controls with an actionable explanation',
      (tester) async {
        messenger.setMockMethodCallHandler(
          _channel,
          (_) async => _snapshot(available: false, issue: issue.key),
        );
        final accounts = owner();
        await accounts.refreshSnapshot();
        await mount(tester, accounts);
        expect(
          tester.widget<FButton>(find.byKey(const Key('codex-login'))).onPress,
          isNull,
        );
        expect(
          tester.widget<FButton>(find.byKey(const Key('codex-import'))).onPress,
          isNull,
        );
        expect(find.textContaining(issue.value), findsOneWidget);
      },
    );
  }

  testDesktopWidgets(
    'unsupported platforms show disabled controls and never call the native bridge',
    (tester) async {
      var nativeCalls = 0;
      messenger.setMockMethodCallHandler(_channel, (_) async {
        nativeCalls++;
        return _snapshot();
      });
      await mount(tester, owner(platform: TargetPlatform.linux));
      expect(find.textContaining('目前仅支持 macOS'), findsOneWidget);
      expect(
        tester.widget<FButton>(find.byKey(const Key('codex-login'))).onPress,
        isNull,
      );
      expect(nativeCalls, 0);
    },
  );

  testDesktopWidgets('leaving the page keeps native authorization running', (
    tester,
  ) async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      return _snapshot(loginPending: call.method == 'codexStartLogin');
    });
    final accounts = owner();
    await accounts.refreshSnapshot();
    await mount(tester, accounts);
    await tester.tap(find.byKey(const Key('codex-login')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(accounts.snapshot.loginPending, isTrue);
    expect(calls, ['codexAccountsStatus', 'codexStartLogin']);
    expect(tester.takeException(), isNull);
  });

  for (final width in [360.0, 480.0, 760.0]) {
    testDesktopWidgets('account controls and details fit width $width', (
      tester,
    ) async {
      messenger.setMockMethodCallHandler(_channel, (_) async => _snapshot());
      final accounts = owner();
      await accounts.refreshSnapshot();
      await mount(tester, accounts, width: width);
      expect(tester.takeException(), isNull);
      await details(tester, 'official-a');
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('codex-switch-official-a')), findsOneWidget);
      expect(find.byKey(const Key('codex-remove-official-a')), findsOneWidget);
    });
  }
}
