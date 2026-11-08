import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Immutable installation of the application's bundled, pinned source tree.
/// No package manager or upstream checkout is consulted at application startup.
class PluginInstallation {
  PluginInstallation._(this.codePath, this.manifest);
  final String codePath;
  final Map<String, dynamic> manifest;
  String get hostPath => '$codePath/vendor/magpie/host.js';
  String get launcherPath => '$codePath/launcher.mjs';
  List<Map<String, Object?>> get plugins => [
    for (final package in manifest['packages'] as List)
      {'spec': package['spec'], 'target': '$codePath/${package['target']}'},
  ];

  static Future<PluginInstallation> prepare(
    String root,
    Future<List<int>> Function(String) readAsset,
  ) async {
    final lock = await readAsset('runtime/upstream.lock.json');
    final manifest = jsonDecode(utf8.decode(lock)) as Map<String, dynamic>;
    if (manifest['schema'] != 1) throw const FormatException('Unknown runtime');
    final files = <String, List<int>>{'upstream.lock.json': lock};
    for (final entry in manifest['files'] as List) {
      final path = _path(entry['target']);
      final bytes = await readAsset('runtime/$path');
      if (sha256.convert(bytes).toString() != entry['sha256']) {
        throw const FormatException('Upstream source checksum mismatch');
      }
      files[path] = bytes;
    }
    for (final file in manifest['localFiles'] as List) {
      final path = _path(file);
      files[path] = await readAsset('runtime/$path');
    }
    final digest = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              for (final e in files.entries)
                [e.key, sha256.convert(e.value).toString()],
            ]),
          ),
        )
        .toString();
    final destination = Directory('$root/code/$digest');
    if (await destination.exists()) {
      for (final e in files.entries) {
        final file = File('${destination.path}/${e.key}');
        if (!await file.exists() ||
            sha256.convert(await file.readAsBytes()) !=
                sha256.convert(e.value)) {
          throw const FormatException('Installed runtime source was modified');
        }
      }
    } else {
      await destination.parent.create(recursive: true);
      final stage = await destination.parent.createTemp('.install-');
      try {
        for (final e in files.entries) {
          final file = File('${stage.path}/${e.key}');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(e.value, flush: true);
        }
        await stage.rename(destination.path);
      } finally {
        if (await stage.exists()) await stage.delete(recursive: true);
      }
    }
    return PluginInstallation._(destination.path, manifest);
  }

  static String _path(Object? value) {
    if (value is! String ||
        !RegExp(r'^[a-zA-Z0-9_.@/-]+$').hasMatch(value) ||
        value.startsWith('/') ||
        value.split('/').contains('..')) {
      throw const FormatException('Invalid runtime path');
    }
    return value;
  }
}
