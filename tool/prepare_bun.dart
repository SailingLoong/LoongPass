import 'dart:convert';
import 'dart:io';

import '../lib/pinned_bun.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1)
    throw ArgumentError('Supply a private cache directory');
  final root = Directory(arguments.single);
  await root.create(recursive: true);
  if (!Platform.isWindows) {
    final result = await Process.run('/bin/chmod', ['700', root.path]);
    if (result.exitCode != 0) throw StateError('Cannot prepare private cache');
  }
  final manifest = jsonDecode(
    await File('runtime/upstream.lock.json').readAsString(),
  );
  stdout.writeln(
    await PinnedBun.prepare(
      root.path,
      Map<String, dynamic>.from(manifest['bun']),
    ),
  );
}
