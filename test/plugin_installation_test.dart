import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/plugin_installation.dart';

void main() {
  test('installs the complete pinned packages and refuses a modified source', () async {
    final root = await Directory.systemTemp.createTemp('loongpass-install-');
    try {
      final installation = await PluginInstallation.prepare(
        root.path,
        (path) => File(path).readAsBytes(),
      );
      expect(
        await File(installation.hostPath).readAsBytes(),
        await File('runtime/vendor/magpie/host.js').readAsBytes(),
      );
      expect(installation.plugins.length, 6);
      expect(
        await File(
          '${installation.codePath}/vendor/plugins/minimax/connector-tools.mjs',
        ).exists(),
        isTrue,
      );
      await expectLater(
        PluginInstallation.prepare(
          root.path,
          (path) async => path.endsWith('/workbuddy/index.mjs')
              ? utf8.encode('modified')
              : File(path).readAsBytes(),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await File(installation.hostPath).exists(), isTrue);
      await installation.publishBridge();
      final firstBridge = await File('${installation.bridgePath}/index.mjs')
          .readAsString();
      final next = await PluginInstallation.prepare(root.path, (path) async {
        final bytes = await File(path).readAsBytes();
        return path == 'runtime/bridge/index.mjs'
            ? [...utf8.encode('// new bundled bridge\n'), ...bytes]
            : bytes;
      });
      await next.publishBridge();
      expect(next.codePath, isNot(installation.codePath));
      expect(next.bridgePath, installation.bridgePath);
      expect(
        await File('${next.bridgePath}/index.mjs').readAsString(),
        '// new bundled bridge\n$firstBridge',
      );
      expect(
        await File('${installation.codePath}/bridge/index.mjs').readAsString(),
        firstBridge,
      );
    } finally {
      await root.delete(recursive: true);
    }
  });
}
