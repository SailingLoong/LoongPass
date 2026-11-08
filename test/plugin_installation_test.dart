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
    } finally {
      await root.delete(recursive: true);
    }
  });
}
