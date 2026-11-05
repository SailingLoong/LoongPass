// Optional local visual receipt, not part of the platform-independent test suite.
// Uses already-installed cloud fonts; does not bundle fonts or read user files.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/main.dart';

void main() {
  setUpAll(() async {
    final bytes = await File(
      '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    ).readAsBytes();
    for (final family in [
      'Roboto',
      'Ahem',
      'CupertinoSystemText',
      'CupertinoSystemDisplay',
      '.AppleSystemUIFont',
    ]) {
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    final icons = await File(
      '../toolchain/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ).readAsBytes();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(Future.value(ByteData.sublistView(icons)))).load();
  });
  for (final width in [1280.0, 480.0]) {
    testWidgets('render imported synthetic ZCode file at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(key: boundaryKey, child: const AccountToolApp()),
      );
      await tester.pumpAndSettle();
      late Directory temporary;
      late File source;
      late Directory privateRoot;
      await tester.runAsync(() async {
        temporary = Directory(
          await (await Directory.systemTemp.createTemp(
            'loongpass-visual-zcode-',
          )).resolveSymbolicLinks(),
        );
        privateRoot = await Directory('${temporary.path}/private').create();
        await Process.run('chmod', ['700', privateRoot.path]);
        source = File('${temporary.path}/synthetic.json');
        await source.writeAsString(
          '{"oauth:active_provider":"SYNTHETIC_PROVIDER","oauth:zai:access_token":"SYNTHETIC_ACCESS","oauth:zai:user_info":"SYNTHETIC_INFO"}',
        );
      });
      const channel = MethodChannel('com.sailingloong.loongpass/files');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'chooseBackupSource'
            ? {'sourcePath': source.path, 'privateRoot': privateRoot.path}
            : null,
      );
      try {
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('backup-file')));
          for (var i = 0; i < 200; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            await tester.pump();
            if (tester
                    .widget<OutlinedButton>(
                      find.byKey(const Key('backup-file')),
                    )
                    .onPressed !=
                null)
              break;
          }
        });
        await tester.pumpAndSettle();
        expect(find.text('已导入文件，身份未验证'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final frame = await boundary.toImage();
          final data = (await frame.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          await File(
            '../evidence/flutter-zcode-import-${width.toInt()}.png',
          ).writeAsBytes(data.buffer.asUint8List());
          frame.dispose();
        });
      } finally {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        await tester.runAsync(() => temporary.delete(recursive: true));
      }
    }, variant: TargetPlatformVariant({TargetPlatform.macOS}));
  }
}
