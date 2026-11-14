import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/app_theme.dart';
import '../lib/app_updates.dart';
import '../lib/invitation_settings.dart';
import '../lib/managed_app.dart';
import '../lib/plugin_accounts.dart';
import '../lib/plugin_runtime.dart';
import '../lib/plugin_sign_in_dialog.dart';
import '../lib/ui_preferences.dart';
import '../lib/workspace_tools.dart';
import 'desktop_test_app.dart';

class _Runtime implements PluginRuntime {
  int calls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    return super.noSuchMethod(invocation);
  }
}

class _Accounts extends ChangeNotifier implements PluginAccounts {
  @override
  final _Runtime runtime = _Runtime();

  @override
  final providers = <String, Map<String, dynamic>>{
    'fixture': {
      'name': '用于验证长文本与大字体的平台名称',
      'methods': [
        {'type': 'oauth', 'label': '通过官方授权窗口添加个人账号并保存本机授权'},
        {'type': 'api', 'label': 'API 密钥'},
      ],
    },
    'other': {
      'name': '另一个平台',
      'methods': [
        {'type': 'oauth', 'label': '官方账号'},
      ],
    },
  };

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testDesktopWidgets(
    'settings keep bounded fields and reachable update controls',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final preferences = UiPreferences();
      final invitation = InvitationSettings(ManagedApp.workbuddy);
      final updates = AppUpdates()
        ..version = '1.0.0-beta.45 (45)'
        ..offeredVersion = '1.0.0-beta.46-preview-with-long-version-name'
        ..canCheck = true
        ..canChangeChannel = true;
      addTearDown(preferences.dispose);
      addTearDown(invitation.dispose);
      addTearDown(updates.dispose);

      for (final configuration in [
        (size: const Size(800, 632), scale: 1.0, brightness: Brightness.light),
        (size: const Size(800, 632), scale: 2.0, brightness: Brightness.dark),
        (size: const Size(1024, 768), scale: 1.0, brightness: Brightness.dark),
      ]) {
        tester.view.physicalSize = configuration.size;
        await tester.pumpWidget(
          DesktopTestApp(
            theme: loongPassTheme(configuration.brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(configuration.scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topRight,
                child: SizedBox(
                  width: configuration.size.width - 196,
                  child: WorkspaceSettingsPage(
                    key: ValueKey(configuration),
                    preferences: preferences,
                    updates: updates,
                    invitations: {ManagedApp.workbuddy: invitation},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(const Key('appearance-theme'))).width,
          closeTo(180 * configuration.scale, 1),
        );
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('检查更新'));
        await tester.pumpAndSettle();
        expect(find.text('检查更新').hitTestable(), findsOneWidget);
        await tester.ensureVisible(find.text('接收 Beta 版更新'));
        await tester.pumpAndSettle();
        expect(find.text('接收 Beta 版更新').hitTestable(), findsOneWidget);
        await tester.ensureVisible(find.text('WorkBuddy 邀请设置'));
        await tester.tap(find.text('WorkBuddy 邀请设置'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('workbuddy-invitation-code')),
          'synthetic-invitation',
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const Key('workbuddy-invitation-save')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('workbuddy-invitation-save')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  testDesktopWidgets(
    'authorization dialog keeps actions visible with large text',
    (tester) async {
      tester.view.physicalSize = const Size(800, 632);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final accounts = _Accounts();
      addTearDown(accounts.dispose);
      await tester.pumpWidget(
        DesktopTestApp(
          theme: loongPassTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => FButton(
                mainAxisSize: MainAxisSize.min,
                onPress: () => showFDialog<void>(
                  context: context,
                  builder: (context, style, animation) => PluginSignInDialog(
                    animation: animation,
                    accounts: accounts,
                    providerIds: const {'fixture', 'other'},
                    title: '添加账号',
                    registrationUrl: Uri.parse(
                      'https://example.test/invitation',
                    ),
                  ),
                ),
                child: const Text('打开授权'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开授权'));
      await tester.pumpAndSettle();
      expect(find.text('开始授权').hitTestable(), findsOneWidget);
      expect(find.text('取消').hitTestable(), findsOneWidget);
      expect(find.byKey(const Key('plugin-auth-provider')), findsOneWidget);
      expect(find.byKey(const Key('plugin-auth-method')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('打开授权').hitTestable(), findsOneWidget);
      expect(accounts.runtime.calls, 0);
    },
  );
}
