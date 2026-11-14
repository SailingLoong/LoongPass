import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/app_theme.dart';
import '../lib/app_sidebar.dart'
    show AppWorkspace, AppWorkspaceState, WorkspaceSection;
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

Future<void> _capturePreview(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  final output = Platform.environment['LOONGPASS_PREVIEW_DIR'];
  if (output == null) return;
  await tester.runAsync(() async {
    final image =
        await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage();
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      final directory = await Directory(output).create(recursive: true);
      await File('${directory.path}/$name.png')
          .writeAsBytes(bytes.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    if (!Platform.environment.containsKey('LOONGPASS_PREVIEW_DIR')) return;
    for (final font in {
      FTypeface.defaultFontFamily:
          'packages/forui/assets/fonts/inter/Inter.ttf',
      'SourceHanSansSC': 'assets/fonts/SourceHanSansSC-VF.ttf',
      'packages/forui_lucide/ForuiLucideIcons':
          'packages/forui_lucide/assets/lucide.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
  });

  testDesktopWidgets(
    'settings keep bounded fields and reachable update controls',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final preferences = UiPreferences();
      final invitation = InvitationSettings(ManagedApp.workbuddy);
      final updates = AppUpdates();
      const channel = MethodChannel('com.sailingloong.loongpass/updates');
      var revision = 0;
      var native = <String, Object?>{};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'state');
            return {...native};
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      addTearDown(preferences.dispose);
      addTearDown(invitation.dispose);
      addTearDown(updates.dispose);

      for (final configuration in [
        (size: const Size(480, 800), scale: 2.0, brightness: Brightness.dark),
        (size: const Size(800, 632), scale: 1.0, brightness: Brightness.light),
        (size: const Size(800, 632), scale: 2.0, brightness: Brightness.dark),
        (size: const Size(1024, 768), scale: 1.0, brightness: Brightness.dark),
      ]) {
        tester.view.physicalSize = configuration.size;
        native = {
          'revision': ++revision,
          'phase': 'idle',
          'version': '1.0.0-beta.45 (45)',
          'offeredVersion': '1.0.0-beta.46-preview-with-long-version-name',
          'canCheck': true,
          'canChangeChannel': true,
          'automaticUpdates': true,
          'receiveBetaUpdates': true,
        };
        await updates.load();
        final boundary = GlobalKey();
        final workspace = GlobalKey<AppWorkspaceState>();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: DesktopTestApp(
              theme: loongPassTheme(configuration.brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(configuration.scale)),
                child: child!,
              ),
              home: FScaffold(
                childPad: false,
                child: AppWorkspace(
                  key: workspace,
                  preferences: preferences,
                  pages: const {
                    ManagedApp.workbuddy: Text('Synthetic accounts'),
                  },
                  sections: {
                    WorkspaceSection.settings: WorkspaceSettingsPage(
                      preferences: preferences,
                      updates: updates,
                      invitations: {ManagedApp.workbuddy: invitation},
                    ),
                  },
                  footerBuilder: (context, compact) => AppUpdateBadge(
                    updates: updates,
                    compact: compact,
                    onOpen: () => workspace.currentState!.selectSection(
                      WorkspaceSection.settings,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        workspace.currentState!.selectSection(WorkspaceSection.settings);
        await tester.pumpAndSettle();
        final appearance = find.byKey(const Key('appearance-theme'));
        final availableWidth = tester
            .getSize(
              find.ancestor(of: appearance, matching: find.byType(Wrap)).first,
            )
            .width;
        expect(
          tester.getSize(appearance).width,
          closeTo(math.min(180 * configuration.scale, availableWidth), 1),
        );
        expect(tester.takeException(), isNull);
        Future<void> scrollTo(Finder target, double delta) async {
          await tester.scrollUntilVisible(
            target,
            delta,
            scrollable: find
                .descendant(
                  of: find.byType(WorkspaceSettingsPage),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pumpAndSettle();
        }

        await scrollTo(find.text('检查更新'), 240);
        expect(find.text('检查更新').hitTestable(), findsOneWidget);
        await scrollTo(find.text('接收 Beta 版更新'), 240);
        expect(find.text('接收 Beta 版更新').hitTestable(), findsOneWidget);
        await scrollTo(find.text('WorkBuddy 邀请设置'), -240);
        await tester.tap(find.text('WorkBuddy 邀请设置'));
        await tester.pumpAndSettle();
        await scrollTo(find.byKey(const Key('workbuddy-invitation-code')), 240);
        await tester.enterText(
          find.byKey(const Key('workbuddy-invitation-code')),
          'synthetic-invitation',
        );
        await tester.pumpAndSettle();
        await scrollTo(find.byKey(const Key('workbuddy-invitation-save')), 240);
        expect(
          find.byKey(const Key('workbuddy-invitation-save')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        for (final phase in ['ready', 'downloading', 'error']) {
          native = {
            ...native,
            'revision': ++revision,
            'phase': phase,
            'canCheck': phase == 'error',
            'canChangeChannel': phase == 'error',
            'canInstall': phase == 'ready',
            'canSkip': phase == 'ready',
            'progress': phase == 'downloading' ? 0.42 : null,
            'error': phase == 'error' ? '网络暂不可用，请稍后重新检查更新。' : null,
          };
          await updates.load();
          await scrollTo(find.text('应用更新'), 240);
          final status = switch (phase) {
            'ready' => '更新已准备好，可重启并更新',
            'downloading' => '正在后台下载更新',
            _ => '更新未完成，可稍后重试',
          };
          expect(
            find
                .descendant(
                  of: find.byType(AppUpdateCard),
                  matching: find.text(status),
                )
                .hitTestable(),
            findsOneWidget,
          );
          expect(find.byType(AppUpdateBadge).hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          await _capturePreview(
            tester,
            boundary,
            'settings-${configuration.size.width.toInt()}-${configuration.brightness.name}-scale-${configuration.scale.toInt()}-$phase',
          );
        }
      }
    },
  );

  testDesktopWidgets(
    'authorization dialog keeps actions visible with large text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final accounts = _Accounts();
      addTearDown(accounts.dispose);
      for (final configuration in [
        (size: const Size(480, 800), scale: 2.0, brightness: Brightness.dark),
        (size: const Size(800, 632), scale: 2.0, brightness: Brightness.dark),
        (size: const Size(1024, 768), scale: 1.0, brightness: Brightness.light),
      ]) {
        tester.view.physicalSize = configuration.size;
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: DesktopTestApp(
              theme: loongPassTheme(configuration.brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(configuration.scale)),
                child: child!,
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => FButton(
                    mainAxisSize: MainAxisSize.min,
                    onPress: () => showFDialog<void>(
                      context: context,
                      builder: (context, style, animation) =>
                          PluginSignInDialog(
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
          ),
        );
        await tester.tap(find.text('打开授权'));
        await tester.pumpAndSettle();
        expect(find.text('开始授权').hitTestable(), findsOneWidget);
        expect(find.text('取消').hitTestable(), findsOneWidget);
        expect(find.byKey(const Key('plugin-auth-provider')), findsOneWidget);
        expect(find.byKey(const Key('plugin-auth-method')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _capturePreview(
          tester,
          boundary,
          'authorization-${configuration.size.width.toInt()}-${configuration.brightness.name}-scale-${configuration.scale.toInt()}',
        );
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.text('打开授权').hitTestable(), findsOneWidget);
        expect(accounts.runtime.calls, 0);
      }
    },
  );
}
