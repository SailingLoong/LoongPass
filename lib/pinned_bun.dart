import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The same pinned official Bun distribution used by the native host upstream.
/// Downloaded once into the private runtime directory, with mandatory SHA-256.
class PinnedBun {
  static Future<String> prepare(String root, Map<String, dynamic> pin) async {
    final name = switch (Abi.current()) {
      Abi.macosArm64 => 'bun-darwin-aarch64',
      Abi.macosX64 => 'bun-darwin-x64',
      Abi.windowsArm64 => 'bun-windows-aarch64',
      Abi.windowsX64 => 'bun-windows-x64-baseline',
      _ => throw const FormatException('Unsupported runtime platform'),
    };
    final version = pin['version'] as String;
    final expected = (pin['archives'] as Map)['$name.zip'] as String;
    final directory = Directory('$root/bun/$version/$name');
    final executable = File(
      '${directory.path}/bun${Platform.isWindows ? '.exe' : ''}',
    );
    final receipt = File('${directory.path}/verified.json');
    if (await executable.exists() && await receipt.exists()) {
      final saved = jsonDecode(await receipt.readAsString());
      if (saved['archive'] == expected &&
          saved['executable'] ==
              (await sha256.bind(executable.openRead()).first).toString()) {
        return executable.path;
      }
      throw const FormatException('Runtime executable checksum mismatch');
    }
    final url = Uri.https(
      'github.com',
      '/oven-sh/bun/releases/download/bun-v$version/$name.zip',
    );
    final bytes = await _download(url);
    final path = await installArchive(directory.path, name, bytes, expected);
    final check = await Process.run(path, ['--version']);
    if (check.exitCode != 0 || (check.stdout as String).trim() != version) {
      throw const FormatException('Runtime executable version mismatch');
    }
    return path;
  }

  static Future<List<int>> _download(Uri url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      for (var redirect = 0; redirect < 6; redirect++) {
        if (url.scheme != 'https')
          throw const FormatException('Invalid runtime download');
        final request = await client.getUrl(url);
        request.followRedirects = false;
        final response = await request.close().timeout(
          const Duration(seconds: 60),
        );
        if (response.isRedirect) {
          final location = response.headers.value('location');
          if (location == null)
            throw const FormatException('Invalid runtime redirect');
          url = url.resolve(location);
          await response.drain<void>();
          continue;
        }
        if (response.statusCode != 200)
          throw const HttpException('Runtime download failed');
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(
          const Duration(seconds: 60),
        )) {
          if (bytes.length + chunk.length > 128 << 20)
            throw const FormatException('Runtime download too large');
          bytes.add(chunk);
        }
        return bytes.takeBytes();
      }
      throw const HttpException('Too many runtime redirects');
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> installArchive(
    String root,
    String name,
    List<int> bytes,
    String expected,
  ) async {
    if (sha256.convert(bytes).toString() != expected) {
      throw const FormatException('Runtime archive checksum mismatch');
    }
    final destination = Directory(root);
    await destination.parent.create(recursive: true);
    final stage = await destination.parent.createTemp('.bun-install-');
    try {
      final archive = File('${stage.path}/bun.zip');
      await archive.writeAsBytes(bytes, flush: true);
      final unpack = await Process.run(
        Platform.isWindows ? 'tar.exe' : '/usr/bin/unzip',
        Platform.isWindows
            ? ['-xf', archive.path, '-C', stage.path]
            : ['-q', archive.path, '-d', stage.path],
      );
      if (unpack.exitCode != 0)
        throw const FormatException('Runtime extraction failed');
      final filename = Platform.isWindows ? 'bun.exe' : 'bun';
      final file = File('${stage.path}/$name/$filename');
      final digest = (await sha256.bind(file.openRead()).first).toString();
      if (!Platform.isWindows) {
        final permissions = await Process.run('/bin/chmod', ['700', file.path]);
        if (permissions.exitCode != 0)
          throw const FileSystemException('Runtime permissions failed');
      }
      await File('${stage.path}/$name/verified.json').writeAsString(
        jsonEncode({'archive': expected, 'executable': digest}),
        flush: true,
      );
      await Directory('${stage.path}/$name').rename(destination.path);
      return '${destination.path}/$filename';
    } finally {
      await stage.delete(recursive: true);
    }
  }
}
