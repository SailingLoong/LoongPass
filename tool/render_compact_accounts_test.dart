// Optional visual acceptance of the real Flutter components, synthetic data only.
// LOONGPASS_PREVIEW_DIR selects the output directory. No native account owners.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:forui/forui.dart';

import '../test/desktop_test_app.dart';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/main.dart';
import '../lib/app_sidebar.dart';
import '../lib/compact_accounts_table.dart';
import '../lib/credit_summary.dart';
import '../lib/claim_receipt.dart';
import '../lib/account_workspace_registry.dart';
import '../lib/workspace_accounts.dart';

void main() {
  setUpAll(() async {
    for (final font in {
      FTypeface.defaultFontFamily:
          'packages/forui/assets/fonts/inter/Inter.ttf',
      'SourceHanSansSC': 'assets/fonts/SourceHanSansSC-VF.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
    for (final font in {
      'packages/forui_lucide/ForuiLucideIcons':
          'packages/forui_lucide/assets/lucide.ttf',
    }.entries) {
      final bytes = await rootBundle.load(font.value);
      final loader = FontLoader(font.key)..addFont(Future.value(bytes));
      await loader.load();
    }
  });
  for (final (size, scale) in [
    (const Size(1280, 800), 1.0),
    (const Size(1024, 768), 1.0),
    (const Size(800, 632), 1.0),
    (const Size(480, 800), 1.0),
    (const Size(480, 800), 2.0),
  ]) {
    for (final brightness in Brightness.values) {
      testDesktopWidgets(
        'compact ${size.width.toInt()} ${brightness.name} scale $scale',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final boundary = GlobalKey();
          final registry = AccountWorkspaceRegistry();
          final workspace = GlobalKey<AppWorkspaceState>();
          addTearDown(registry.dispose);
          final entries = [
            for (var n = 1; n <= 4; n++)
              AccountTableEntry(
                id: '$n',
                label: n == 1
                    ? 'demo@example.test'
                    : '备用账号 ${n.toString().padLeft(2, '0')}',
                identity: 'demo$n@example.test',
                balance: '${880 + n * 60} 积分',
                credits: CreditSummary(
                  880.0 + n * 60,
                  260.0 + n * 60,
                  DateTime(2026, 11, 14, 10, 20),
                  [
                    CreditExpiry(DateTime.now().add(Duration(days: n)), 120),
                    CreditExpiry(
                      DateTime.now().add(Duration(days: n + 7)),
                      200,
                    ),
                    CreditExpiry(
                      DateTime.now().add(Duration(days: n + 14)),
                      300,
                    ),
                  ],
                ),
                status: n == 2 ? '领取结果待核对' : '辅助领取已开启',
                needsAttention: n == 2,
                receipt: ClaimReceipt(
                  amount: 100,
                  confirmedAt: DateTime(2026, 11, 14, 9, 30),
                ),
                onActivate: () {},
                automatic: true,
                details: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('身份：demo$n@example.test'),
                    const SizedBox(height: 8),
                    Text(n == 2 ? '领取结果待核验，仅查询官方状态，不会重复发送。' : '已保存的官方账号'),
                    const SizedBox(height: 16),
                    FButton(
                      size: FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: () {},
                      child: Text(n == 2 ? '核验领取结果' : '刷新额度'),
                    ),
                  ],
                ),
              ),
          ];
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: DesktopTestApp(
                theme: loongPassTheme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: FScaffold(
                  childPad: false,
                  child: AppWorkspace(
                    key: workspace,
                    initialApp: ManagedApp.workbuddy,
                    sections: {
                      WorkspaceSection.models: const Text('模型连接演示'),
                      WorkspaceSection.overview: WorkspaceOverviewPage(
                        registry: registry,
                        onOpenApp: (app) =>
                            workspace.currentState!.selectApp(app),
                      ),
                      WorkspaceSection.accounts: WorkspaceAccountsPage(
                        registry: registry,
                      ),
                      WorkspaceSection.activity: WorkspaceActivityPage(
                        registry: registry,
                      ),
                    },
                    pages: {
                      ManagedApp.workbuddy: AccountPresentationScope(
                        app: ManagedApp.workbuddy,
                        registry: registry,
                        child: AccountWorkspacePage(
                          'WorkBuddy',
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AccountPanelToolbar(
                                title: 'WorkBuddy',
                                accountCount: entries.length,
                                helpText: '演示数据，不操作真实账号。',
                                actions: [
                                  FButton(
                                    mainAxisSize: MainAxisSize.min,
                                    size: FButtonSizeVariant.sm,
                                    onPress: () {},
                                    child: const Text('添加账号'),
                                  ),
                                  FButton(
                                    variant: FButtonVariant.ghost,
                                    mainAxisSize: MainAxisSize.min,
                                    size: FButtonSizeVariant.sm,
                                    onPress: () {},
                                    child: const Text('刷新账号与额度'),
                                  ),
                                ],
                              ),
                              const Text(
                                '演示数据 · 客户端当前账号：尚未核对',
                                style: TextStyle(fontSize: 12),
                              ),
                              CompactAccountsTable(entries: entries),
                            ],
                          ),
                          showTitle: false,
                        ),
                      ),
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            final context = tester.element(find.byKey(workspace));
            await Future.wait([
              precacheImage(
                const AssetImage('assets/branding/loongpass.png'),
                context,
              ),
              for (final app in ManagedApp.values)
                precacheImage(AssetImage(app.iconAsset), context),
            ]);
          });
          await tester.pumpAndSettle();
          workspace.currentState!.selectApp(ManagedApp.workbuddy);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          Future<void> capture(String name) => tester.runAsync(() async {
            final canvas =
                boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await canvas.toImage();
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            final output = Directory(
              Platform.environment['LOONGPASS_PREVIEW_DIR'] ??
                  'artifacts/compact-ui',
            );
            await output.create(recursive: true);
            await File(
              '${output.path}/flutter-workspace-${size.width.toInt()}${scale > 1 ? '-large-text' : ''}-${brightness.name}-$name.png',
            ).writeAsBytes(bytes.buffer.asUint8List());
            image.dispose();
          });
          await capture('accounts');
          await tester.ensureVisible(find.byKey(const Key('account-1')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('account-1')));
          await tester.pumpAndSettle();
          await capture('details');
          await tester.tap(find.text('关闭'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.byKey(const Key('expiry-1')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('expiry-1')));
          await tester.pumpAndSettle();
          await capture('expiry');
          await tester.tap(find.text('关闭'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.byKey(const Key('account-search')));
          await tester.enterText(
            find.byKey(const Key('account-search')),
            'no-matching-account',
          );
          await tester.pumpAndSettle();
          await capture('empty-search');
          await tester.tap(find.text('清除搜索和筛选'));
          await tester.pumpAndSettle();
          if (size.width == 1024) {
            await tester.tap(find.byKey(const Key('toggle-sidebar')));
            await tester.pumpAndSettle();
            await capture('collapsed');
            await tester.tap(find.byKey(const Key('toggle-sidebar')));
            await tester.pumpAndSettle();
          }
          for (final section in ['overview', 'activity', 'settings']) {
            await tester.tap(find.byKey(ValueKey('nav-$section')));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await capture(section);
          }
        },
        variant: TargetPlatformVariant({TargetPlatform.macOS}),
      );
    }
  }
}
