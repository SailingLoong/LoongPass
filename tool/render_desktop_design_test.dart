// Run through the shared Flutter gate. Set LOONGPASS_PREVIEW_DIR to save PNGs
// and logical widget bounds. All account and updater inputs are synthetic.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/app_update_view.dart';
import '../lib/main.dart';
import '../lib/managed_app.dart';
import '../lib/model_connection.dart';
import '../lib/plugin_accounts.dart';
import '../lib/plugin_application.dart';
import '../lib/plugin_rewards.dart';
import '../lib/ui_preferences.dart';
import '../lib/update_contract.dart';
import '../lib/workspace_page.dart';
import '../lib/workspace_toolbar.dart';
import '../lib/zcode_api.dart';
import '../test/desktop_test_app.dart';
import '../test/desktop_design_scenarios.dart';
import '../test/model_workspace_fixture.dart';

class _ObservedRewards extends PluginRewards {
  _ObservedRewards(super.accounts) : super(timers: false);
  final reads = <String>[];
  final claims = <String>[];
  final response = Completer<void>();

  @override
  Future<void> refresh(String key, {bool includeUsage = false}) {
    reads.add(key);
    return response.future;
  }

  @override
  Future<void> claim(
    String key, {
    Future<String?> Function(ZcodeCaptchaConfig)? verify,
  }) async => claims.add(key);
}

class _DesignAccounts extends WorkspaceFixtureAccounts {
  @override
  Set<String> get enabledProviders => {
    ...super.enabledProviders,
    'minimax-code',
  };
}

class _DesignApplication implements PluginApplication {
  @override
  final WorkspaceFixtureAccounts accounts = _DesignAccounts();
  @override
  late final WorkspaceFixtureModels models = WorkspaceFixtureModels(accounts);
  @override
  late final _ObservedRewards rewards = _ObservedRewards(accounts);
  @override
  late final connection = ModelConnection(models, '/synthetic/bridge');

  Future<void> dispose() async {
    await rewards.close();
    connection.dispose();
    models.dispose();
    accounts.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
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

  for (final (mode, size, scale, phase, progress) in [
    ('light', const Size(1080, 748), 1.0, 'downloading', 0.25),
    ('dark', const Size(1080, 748), 1.0, 'ready', null),
    ('narrow', const Size(430, 750), 2.0, 'downloading', null),
  ]) {
    testDesktopWidgets('desktop design $mode', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final app = _DesignApplication();
      app.accounts.accounts.removeRange(6, 13);
      app.accounts.providers['qoder-cn'] = {
        'checkin': true,
        'checkinStatus': true,
      };
      final first = app.accounts.accounts.first;
      final today = DateTime.now();
      final observedAt = DateTime(today.year, today.month, today.day, 11, 26);
      final queriedAt = DateTime(today.year, today.month, today.day, 16, 48);
      final nextExpiry = DateTime(today.year, today.month, today.day + 2);
      final otherExpiry = DateTime(today.year, today.month, today.day + 4, 18);
      first.usage!['windows'][0]['runsOutAt'] = DateTime(
        today.year,
        today.month,
        today.day,
        23,
        59,
        59,
        999,
      ).toIso8601String();
      first.facts['label'] = '跨地区研发验证账号-长名称与拉丁字符-Synthetic-Workspace-01';
      first.usage!['windows'].add({
        'name': '独立批次',
        'unit': 'credits',
        'aside': true,
        'runsOutAt': otherExpiry.toIso8601String(),
        'runsOut': 100,
      });
      const longModel = 'kimi-k2.7-code-highspeed';
      first.models.add({'id': longModel});
      app.models.routingSettings['published'][longModel] = true;
      app.accounts.accounts[1].facts['reward'] = {
        'status': 'authorization_required',
      };
      final pendingAccount = app.accounts.accounts[2];
      pendingAccount.facts['reward'] = {
        'status': 'pending',
        'attemptId': 'synthetic-attempt',
        'submittedAt': today.millisecondsSinceEpoch,
      };
      final observedAccount = app.accounts.accounts[4];
      observedAccount.facts['reward'] = {
        'status': 'unavailable',
        'outcome': 'unknown',
        'observedAt': today.millisecondsSinceEpoch,
      };
      app.accounts.accounts[3].facts['reward'] = {
        'status': 'claimed',
        'credit': 12.5,
        'unit': 'credits',
        'confirmedAt': DateTime.now().millisecondsSinceEpoch,
      };
      app.accounts.providers['minimax-code'] = {'checkin': true};
      final miniMax = PluginAccount(
        key: 'studio',
        active: true,
        facts: {
          'provider': 'minimax-code',
          'realm': 'cn',
          'uid': 'synthetic-studio',
          'label': '云帆工作室',
          'registrationId': 'synthetic-studio-registration',
          'reward': {
            'status': 'claimed',
            'credit': 400,
            'unit': 'credits',
            'observedAt': observedAt.millisecondsSinceEpoch,
          },
        },
        models: [
          {'id': 'MiniMax-M3'},
        ],
        usage: {
          'plan': 'Free',
          'windows': [
            {
              'name': 'Credits',
              'unit': 'credits',
              'limit': 13224,
              'amount': 0,
              'used': 0,
              'runsOut': 1424,
              'runsOutAt': nextExpiry.toIso8601String(),
            },
          ],
        },
        queriedAt: queriedAt,
      );
      app.accounts.accounts.insert(0, miniMax);
      final prefs = UiPreferences()
        ..setTheme(mode == 'light' ? ThemeMode.light : ThemeMode.dark);
      addTearDown(app.dispose);
      addTearDown(prefs.dispose);
      const files = MethodChannel('com.sailingloong.loongpass/files');
      final fileCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(files, (
        call,
      ) async {
        fileCalls.add(call.method);
        return {
          'available': true,
          'busy': false,
          'loginPending': false,
          'accounts': [
            {
              'id': 'synthetic-codex',
              'email': 'desktop@example.test',
              'plan': 'Team',
            },
          ],
        };
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          files,
          null,
        ),
      );
      const channel = MethodChannel(UpdateContract.channel);
      final calls = <String>[];
      final snapshot = {
        'revision': 1,
        'version': '0.9.0',
        'offeredVersion': '0.9.1',
        'phase': phase,
        'canInstall': phase == 'ready',
        'canCheck': false,
        'progress': progress,
        'downloadedBytes': 1048576,
      };
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        return snapshot;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: AccountToolApp(application: app, preferences: prefs),
        ),
      );
      // Bounded frames also support indeterminate progress animations.
      Future<void> frame() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));
        await tester.pump();
      }

      await frame();
      await tester.runAsync(() async {
        final context = tester.element(find.byType(AccountToolApp));
        await Future.wait([
          precacheImage(
            const AssetImage('assets/branding/loongpass.png'),
            context,
          ),
          for (final app in ManagedApp.values)
            precacheImage(AssetImage(app.iconAsset), context),
        ]);
      });
      await frame();
      final output = Platform.environment['LOONGPASS_PREVIEW_DIR'];
      if (progress != null) {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(UpdateContract.stateChanged, {
              ...snapshot,
              'revision': 2,
              'downloadedBytes': 1048576 + 272 * 1024,
            }),
          ),
          (_) {},
        );
      }
      Finder key(String value) => find.byKey(ValueKey(value));
      final crowdedControls = <String>[];
      Future<void> capture(String scene) async {
        expect(tester.takeException(), isNull);
        if (output == null) return;
        final metrics = <String, Object?>{};
        if (scene.startsWith('pending')) {
          metrics['refreshCalls'] = [...app.rewards.reads];
          metrics['claimCalls'] = [...app.rewards.claims];
        }
        void record(String name, Finder finder) {
          if (finder.evaluate().isEmpty) return;
          final r = tester.getRect(finder.first);
          metrics[name] = [r.left, r.top, r.width, r.height];
        }

        record('rail', key('app-sidebar'));
        record('logo', key('app-brand'));
        record('settings', key('nav-settings'));
        record('update', find.byType(AppUpdateBadge));
        record('toolbar', find.byType(WorkspaceToolbar));
        record('workspace', key('workspace-body'));
        record('detail', key('account-detail-page'));
        record('balance', find.text('13,224 credits'));
        record('expiry', key('detail-expiry'));
        record('receipt', key('detail-receipt'));
        record('back', key('account-back'));
        record('nav', key('nav-$scene'));
        if (scene.startsWith('pending')) {
          record('verifyButton', find.widgetWithText(FButton, '核验结果'));
        }
        record(
          'search',
          key(scene == 'accounts' ? 'account-search' : 'model-search'),
        );
        for (final page in tester.widgetList<WorkspacePage>(
          find.byType(WorkspacePage),
        )) {
          if (page.action case final control?)
            record('action', find.byWidget(control));
          record(
            'heading',
            find.descendant(
              of: find.byWidget(page),
              matching: find.text(page.title),
            ),
          );
        }
        for (final label in [
          '辅助签到',
          '添加账号',
          '重启并更新',
          '最近到期',
          '套餐与额度',
          '版本与更新',
        ]) {
          record(label, find.text(label).hitTestable());
        }
        await tester.runAsync(() async {
          final dir = await Directory(output).create(recursive: true);
          final prefix = '${dir.path}/$mode-$scene';
          final canvas =
              boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await canvas.toImage();
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            await File('$prefix.png').writeAsBytes(
              bytes.buffer.asUint8List(
                bytes.offsetInBytes,
                bytes.lengthInBytes,
              ),
            );
            await File('$prefix.json').writeAsString(jsonEncode(metrics));
          } finally {
            image.dispose();
          }
        });
      }

      for (final section in [
        'overview',
        'accounts',
        'models',
        'activity',
        'settings',
      ]) {
        await tapWorkspaceDestination(tester, section, frame);
        expect(key('section-$section'), findsOneWidget);
        await capture(section);
        if (section == 'settings' && mode != 'light') {
          await inspectSettings(tester, frame, capture);
        }
        if (section == 'activity') {
          final receipts = find.textContaining(RegExp(r'^最近(领取|回执) \d+$'));
          await tester.ensureVisible(receipts.last);
          await tester.tap(receipts.hitTestable().last);
          await frame();
          await capture('receipts');
          final pendingTab = find.textContaining(RegExp(r'^待处理 \d+$'));
          await tester.ensureVisible(pendingTab);
          await tester.tap(pendingTab.hitTestable());
          await frame();
          expect(find.text(observedAccount.label), findsOneWidget);
          expect(find.text(pendingAccount.label), findsOneWidget);
          final verify = find.text('核验结果');
          expect(verify, findsOneWidget);
          if (verify.hitTestable().evaluate().isEmpty) {
            await tester.ensureVisible(verify);
            await frame();
          }
          await capture('pending');
          expect(app.rewards.reads, isEmpty);
          expect(app.rewards.claims, isEmpty);
          await tester.tap(verify.hitTestable());
          await frame();
          expect(app.rewards.reads, [pendingAccount.key]);
          expect(app.rewards.claims, isEmpty);
          expect(verify, findsNothing);
          await capture('pending-checking');
          app.rewards.response.complete();
          await frame();
          expect(verify, findsOneWidget);
          expect(app.rewards.reads, [pendingAccount.key]);
          expect(app.rewards.claims, isEmpty);
          if (mode == 'narrow') {
            await tester.ensureVisible(find.textContaining('活动查询未完成').last);
            await frame();
          }
          await capture('pending-verified');
        }
        if (section == 'overview') {
          if (progress != null)
            expect(find.text('272.0 KiB/s'), findsOneWidget);
          await inspectCalendarReturn(
            tester,
            first.label,
            otherExpiry,
            frame,
            capture,
          );
        }
        if (section == 'models') {
          await inspectModelReturn(
            tester,
            frame,
            (name) => capture('model-$name'),
          );
          await tester.enterText(key('model-search'), '');
          await frame();
          for (final label in ['显示全部模型', '连接设置']) {
            final text = find.text(label);
            final bounds = tester.getSize(text.last);
            if (bounds.width < bounds.height) crowdedControls.add(label);
          }
          await tester.ensureVisible(find.text('连接设置'));
          await tester.tap(find.text('连接设置').hitTestable());
          await frame();
          await capture('connection');
          await tester.tap(find.bySemanticsLabel('关闭连接设置').hitTestable().last);
          await frame();
          final filter = key('show-all-models');
          await tester.ensureVisible(filter);
          await tester.tap(filter);
          await frame();
          expect(tester.widget<FSwitch>(filter).value, isTrue);
          await tester.tap(filter);
          await frame();
          expect(tester.widget<FSwitch>(filter).value, isFalse);
          final row = key('model-$longModel');
          await tester.scrollUntilVisible(
            row,
            260,
            scrollable: find
                .descendant(
                  of: find.byType(WorkspacePage),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await frame();
          expect(
            find
                .descendant(of: row, matching: find.text(longModel))
                .hitTestable(),
            findsOneWidget,
          );
          if (mode == 'narrow') await capture('long-model');
        }
        if (section == 'accounts') {
          await tester.tap(find.text('添加账号').hitTestable());
          await frame();
          expect(find.text('选择平台'), findsWidgets);
          await tester.tap(find.text('取消').hitTestable());
          await frame();
          await inspectAccountReturn(
            tester,
            miniMax.label,
            nextExpiry,
            observedAt,
            frame,
            capture,
          );
        }
      }
      expect(app.accounts.refreshes, 0);
      expect(calls, [UpdateContract.state]);
      final badge = find
          .descendant(
            of: find.byType(AppUpdateBadge),
            matching: find.byType(FButton),
          )
          .hitTestable();
      await tester.tap(badge);
      await frame();
      if (phase == 'ready') {
        await capture('restart-click');
        // A design confirmation must precede dispatch to the native engine.
        expect(calls, [UpdateContract.state], reason: '重启前应能取消');
        await tester.tap(find.text('取消').hitTestable());
        await frame();
        expect(calls, [UpdateContract.state]);
      } else {
        await capture('download-settings');
        expect(find.byType(AppUpdateCard), findsOneWidget);
        expect(find.text(progress == null ? '进度未知' : '25%'), findsWidgets);
        expect(calls, [UpdateContract.state]);
      }
      await inspectUpdateRail(
        tester,
        snapshot,
        mode == 'narrow',
        frame,
        capture,
      );
      expect(calls, [UpdateContract.state]);
      expect(fileCalls, isNotEmpty);
      expect(fileCalls.toSet(), {'codexAccountsStatus'});
      expect(crowdedControls, isEmpty, reason: '模型页的短操作标签应横排');
    }, variant: TargetPlatformVariant({TargetPlatform.macOS}));
  }
}
