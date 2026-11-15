// Visual acceptance of the actual application with synthetic, read-only owners.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/app_sidebar.dart';
import '../lib/main.dart';
import '../lib/ui_preferences.dart';
import '../test/desktop_test_app.dart';
import '../test/model_workspace_fixture.dart';

void main() {
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
  for (final (size, scale) in [
    (const Size(1024, 768), 1.0),
    (const Size(800, 628), 1.0),
    (const Size(480, 800), 2.0),
  ]) {
    for (final brightness in Brightness.values) {
      testDesktopWidgets(
        'model workspace ${size.width} ${brightness.name} scale $scale',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final app = ModelWorkspaceFixture();
          final preferences = UiPreferences()
            ..setModelsExpanded(true)
            ..setTheme(
              brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
            );
          addTearDown(app.dispose);
          addTearDown(preferences.dispose);
          final boundary = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: AccountToolApp(application: app, preferences: preferences),
            ),
          );
          await tester.pumpAndSettle();
          final workspace = tester.state<AppWorkspaceState>(
            find.byType(AppWorkspace),
          );
          Future<void> capture(String suffix) => tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            final directory = Directory(
              Platform.environment['LOONGPASS_PREVIEW_DIR'] ??
                  'artifacts/model-ui',
            );
            await directory.create(recursive: true);
            await File(
              '${directory.path}/models-${size.width.toInt()}-${brightness.name}-$suffix.png',
            ).writeAsBytes(bytes.buffer.asUint8List());
            image.dispose();
          });
          workspace.selectModel('auto');
          await tester.pumpAndSettle();
          await capture('auto');
          workspace.selectModel('deepseek-flash');
          await tester.pumpAndSettle();
          await capture('accounts');
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.text('日常账号 14').hitTestable());
          await tester.tap(find.text('日常账号 14').hitTestable());
          await tester.pumpAndSettle();
          await capture('account-link');
          expect(
            find.byKey(const Key('account-qoderCn/saved-13')).hitTestable(),
            findsOneWidget,
          );
          expect(app.accounts.refreshes, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
