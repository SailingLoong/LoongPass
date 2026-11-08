// Optional visual acceptance of the real Flutter components, synthetic data only.
// LOONGPASS_PREVIEW_DIR selects the output directory. No native account owners.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
    final font = await File(
      '/System/Library/Fonts/STHeiti Light.ttc',
    ).readAsBytes();
    for (final name in ['Roboto', 'Ahem', '.AppleSystemUIFont']) {
      await (FontLoader(
        name,
      )..addFont(Future.value(ByteData.sublistView(font)))).load();
    }
    final sdk =
        Platform.environment['FLUTTER_ROOT'] ?? '/Users/allen/lib/flutter';
    final icons = await File(
      '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ).readAsBytes();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(Future.value(ByteData.sublistView(icons)))).load();
  });
  for (final size in [
    const Size(1024, 720),
    const Size(800, 632),
    const Size(480, 800),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('compact ${size.width.toInt()} ${brightness.name}', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final boundary = GlobalKey();
        final registry = AccountWorkspaceRegistry();
        final workspace = GlobalKey<AppWorkspaceState>();
        addTearDown(registry.dispose);
        final entries = [
          for (var n = 1; n <= 20; n++)
            AccountTableEntry(
              id: '$n',
              label: n == 1 ? '日常开发' : '备用账号 ${n.toString().padLeft(2, '0')}',
              identity: 'demo$n@example.test',
              balance: '${880 + n * 60} 积分',
              credits: CreditSummary(
                880.0 + n * 60,
                260,
                DateTime(2026, 11, 6, 10, 20),
                [
                  CreditExpiry(DateTime(2026, 11, 7 + n), 120),
                  CreditExpiry(DateTime(2026, 11, 10 + n), 200),
                  CreditExpiry(DateTime(2026, 11, 13 + n), 300),
                ],
              ),
              status: n == 5 ? '领取结果待核对' : '辅助领取已开启',
              needsAttention: n == 5,
              receipt: ClaimReceipt(
                amount: 100,
                confirmedAt: DateTime(2026, 11, 6, 9, 30),
              ),
              onActivate: () {},
              details: const Text('演示账号详情'),
            ),
        ];
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: loongPassTheme(brightness),
              home: Scaffold(
                body: AppWorkspace(
                  key: workspace,
                  initialApp: ManagedApp.workbuddy,
                  sections: {
                    WorkspaceSection.overview: WorkspaceOverviewPage(
                      registry: registry,
                      onOpenApp: (app) =>
                          workspace.currentState!.selectApp(app),
                      onOpenModels: () => workspace.currentState!.selectSection(
                        WorkspaceSection.models,
                      ),
                    ),
                    WorkspaceSection.accounts: WorkspaceAccountsPage(
                      registry: registry,
                    ),
                    WorkspaceSection.activity: WorkspaceActivityPage(
                      registry: registry,
                      onOpenApp: (app) =>
                          workspace.currentState!.selectApp(app),
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
                                FilledButton(
                                  onPressed: () {},
                                  child: const Text('添加账号'),
                                ),
                                TextButton(
                                  onPressed: () {},
                                  child: const Text('恢复已保存账号'),
                                ),
                              ],
                            ),
                            const Text(
                              '演示数据 · 客户端当前账号：尚未核对',
                              style: TextStyle(fontSize: 11),
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
            precacheImage(const AssetImage('assets/branding/loongpass.png'), context),
            for (final app in ManagedApp.values)
              precacheImage(AssetImage(app.iconAsset), context),
          ]);
        });
        await tester.pumpAndSettle();
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(
          tester.getCenter(find.byKey(const Key('activate-1'))),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (size.width == 1024) {
          expect(tester.getBottomLeft(find.byTooltip('下一页')).dy, lessThan(700));
          expect(
            tester.getTopLeft(find.byKey(const Key('account-2'))).dy -
                tester.getTopLeft(find.byKey(const Key('account-1'))).dy,
            36,
          );
        }
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
            '${output.path}/flutter-workspace-${size.width.toInt()}-${brightness.name}-$name.png',
          ).writeAsBytes(bytes.buffer.asUint8List());
          image.dispose();
        });
        await capture('accounts');
        await mouse.moveTo(Offset.zero);
        if (size.width == 1024) {
          await tester.tap(find.byKey(const Key('toggle-sidebar')));
          await tester.pumpAndSettle();
          await capture('collapsed');
          await tester.tap(find.byKey(const Key('toggle-sidebar')));
          await tester.pumpAndSettle();
        }
        for (final section in ['overview', 'models', 'activity', 'settings']) {
          await tester.tap(find.byKey(ValueKey('nav-$section')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await capture(section);
        }
        await mouse.removePointer();
      }, variant: TargetPlatformVariant({TargetPlatform.macOS}));
    }
  }
}
