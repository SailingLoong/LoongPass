// Visual acceptance of the real model page with synthetic, read-only owners.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/app_theme.dart';
import '../lib/app_sidebar.dart';
import '../lib/plugin_accounts.dart';
import '../lib/plugin_application.dart';
import '../lib/plugin_model_service.dart';
import '../lib/plugin_model_page.dart';
import '../test/desktop_test_app.dart';

class _Service extends ChangeNotifier implements PluginModelService {
  int changes = 0;
  void publish() => notifyListeners();
  @override
  bool get enabled => true;
  @override
  bool get running => true;
  @override
  String? get error => null;
  @override
  final grants = [
    PluginModelGrant(
      PluginAccount(
        key: 'zcode#one',
        active: true,
        facts: {
          'provider': 'zcode',
          'uid': 'demo',
          'label': 'Demo account',
          'realm': 'bigmodel',
          'registrationId': 'one',
        },
        models: [
          for (var i = 1; i <= 20; i++)
            {
              'id': i == 20 ? 'GLM-Trial' : 'GLM-$i',
              'name': i == 20 ? 'GLM Trial' : 'GLM $i',
            },
        ],
      ),
      'synthetic',
      true,
    ),
  ];
  @override
  Future<void> enable(String key, bool enabled) async {
    changes++;
  }

  @override
  Future<void> setEnabled(bool value) async {
    changes++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Application implements PluginApplication {
  _Application(this.models);
  @override
  final PluginModelService models;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
    (const Size(480, 800), 2.0),
  ]) {
    for (final brightness in Brightness.values) {
      testDesktopWidgets(
        'model catalog ${size.width} ${brightness.name} scale $scale',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final service = _Service();
          addTearDown(service.dispose);
          final boundary = GlobalKey();
          final workspace = GlobalKey<AppWorkspaceState>();
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
                    pages: const {
                      ManagedApp.workbuddy: Text('Synthetic accounts'),
                    },
                    sections: {
                      WorkspaceSection.models: PluginModelServicesPage(
                        application: _Application(service),
                      ),
                    },
                  ),
                ),
              ),
            ),
          );
          workspace.currentState!.selectSection(WorkspaceSection.models);
          await tester.pumpAndSettle();
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
                  'artifacts/compact-ui',
            );
            await directory.create(recursive: true);
            await File(
              '${directory.path}/models-${size.width.toInt()}-${brightness.name}-$suffix.png',
            ).writeAsBytes(bytes.buffer.asUint8List());
            image.dispose();
          });
          await capture('collapsed');
          await tester.ensureVisible(find.text('查看 20 个模型'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('查看 20 个模型'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('GLM Trial · 仅赠送'));
          await tester.pumpAndSettle();
          await capture('expanded');
          expect(find.text('GLM Trial · 仅赠送').hitTestable(), findsOneWidget);
          expect(service.changes, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
