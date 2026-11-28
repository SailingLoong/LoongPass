import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'operation_log.dart';

final _filename = RegExp(
  r'^LoongPass-(\d{4}-\d{2}-\d{2})-\d{6}(?:\.\d+)?\.ips$',
);
final _uuid = RegExp(r'^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$');

/// CrashReporter has already unwound the failed process. Never try to unwind
/// the Flutter engine or touch Dart and the filesystem from a signal handler.
void collectMacCrashReports() {
  final log = OperationLog.current;
  final home = Platform.environment['HOME'];
  if (!Platform.isMacOS || log == null || home == null) return;
  final info = p.normalize(
    p.join(p.dirname(Platform.resolvedExecutable), '..', 'Info.plist'),
  );
  final source = Directory(
    p.join(home, 'Library', 'Logs', 'DiagnosticReports'),
  );
  final destination = log.directory;
  Future<void> collect() async {
    try {
      final result = await Process.run('/usr/bin/plutil', [
        '-extract',
        'CFBundleIdentifier',
        'raw',
        '-o',
        '-',
        info,
      ]);
      if (result.exitCode != 0) return;
      final bundle = (result.stdout as String).trim();
      await Isolate.run(
        () =>
            importMacCrashReports(source, destination, bundle, DateTime.now()),
      );
    } on IOException {
      // System reports are optional. A later launch retries inaccessible files.
    }
  }

  unawaited(collect());
  // CrashReporter can finish its report after macOS has already relaunched us.
  Timer(const Duration(minutes: 1), collect);
}

Future<void> importMacCrashReports(
  Directory source,
  Directory destination,
  String bundle,
  DateTime now,
) async {
  final first = DateTime(
    now.year,
    now.month,
    now.day - OperationLog.retentionDays + 1,
  ).toIso8601String().substring(0, 10);
  final last = now.toIso8601String().substring(0, 10);
  if (!await destination.exists() ||
      await FileSystemEntity.isLink(destination.path))
    return;
  for (final folder in [source, Directory(p.join(source.path, 'Retired'))]) {
    if (!await folder.exists()) continue;
    await for (final entry in folder.list(followLinks: false)) {
      if (entry is! File) continue;
      final day = _filename.firstMatch(p.basename(entry.path))?[1];
      if (day == null || day.compareTo(first) < 0 || day.compareTo(last) > 0)
        continue;
      try {
        await _importReport(entry, destination, bundle, day);
      } on IOException {
        continue;
      } on FormatException {
        // A partially written IPS will be picked up on the next pass.
        continue;
      }
    }
  }
}

Future<void> _importReport(
  File source,
  Directory output,
  String bundle,
  String day,
) async {
  final reader = await source.open();
  late String content;
  try {
    final length = await reader.length();
    if (length > 16 << 20) return;
    content = utf8.decode(await reader.read(length));
  } finally {
    await reader.close();
  }
  final separator = content.indexOf('\n');
  if (separator < 0) return;
  final header = jsonDecode(content.substring(0, separator));
  if (header is! Map ||
      header['bundleID'] != bundle ||
      header['app_name'] != 'LoongPass')
    return;
  final id = header['incident_id'];
  if (id is! String || !_uuid.hasMatch(id)) return;
  final file = File(p.join(output.path, 'crash-$day-$id.json'));
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.notFound)
    return;
  final data = jsonDecode(content.substring(separator + 1));
  if (data is! Map) return;
  final threads = data['threads'];
  final index = data['faultingThread'];
  final images = data['usedImages'];
  if (threads is! List ||
      index is! int ||
      index < 0 ||
      index >= threads.length ||
      images is! List)
    return;
  final thread = threads[index];
  if (thread is! Map || thread['frames'] is! List) return;
  final frames = <Map<String, dynamic>>[];
  for (final frame in (thread['frames'] as List).whereType<Map>().take(96)) {
    final n = frame['imageIndex'];
    if (n is! int || n < 0 || n >= images.length || images[n] is! Map) continue;
    final image = images[n] as Map;
    frames.add({
      'image': image['name'] is String
          ? p.basename(image['name'] as String)
          : 'unknown',
      if (image['uuid'] is String) 'uuid': image['uuid'],
      if (frame['imageOffset'] is int) 'offset': frame['imageOffset'],
      if (frame['symbol'] is String) 'symbol': frame['symbol'],
      if (frame['sourceFile'] is String)
        'source': p.basename(frame['sourceFile'] as String),
      if (frame['sourceLine'] is int) 'line': frame['sourceLine'],
    });
  }
  if (frames.isEmpty) return;
  final capture = data['captureTime'] ?? header['timestamp'];
  final previous = await _lastOperation(
    output,
    data['pid'],
    data['procLaunch'],
    capture,
  );
  final summary = {
    'incident': id,
    'time': capture,
    'launch': data['procLaunch'],
    'pid': data['pid'],
    'version': header['app_version'],
    'build': header['build_version'],
    'exception': data['exception'] is Map ? data['exception']['type'] : null,
    'thread': index,
    'stack': frames,
    if (previous != null) 'lastOperation': previous,
  };
  final temporary = File(
    '${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
  );
  try {
    await temporary.writeAsString('${jsonEncode(summary)}\n', flush: true);
    await temporary.rename(file.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}

Future<Map<String, Object?>?> _lastOperation(
  Directory directory,
  Object? pid,
  Object? launch,
  Object? capture,
) async {
  if (pid is! int || launch is! String || capture is! String) return null;
  final start = DateTime.tryParse(launch);
  final end = DateTime.tryParse(capture);
  if (start == null || end == null) return null;
  final local = end.toLocal();
  for (var offset = 0; offset < OperationLog.retentionDays; offset++) {
    final day = DateTime(local.year, local.month, local.day - offset);
    if (!DateTime(day.year, day.month, day.day + 1).isAfter(start)) break;
    final key = day.toIso8601String().substring(0, 10);
    final name = 'operations-$key.jsonl';
    final file = File(p.join(directory.path, name));
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file)
      continue;
    Map<String, Object?>? last;
    await for (final line
        in file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      try {
        final row = jsonDecode(line);
        if (row is! Map || row['pid'] != pid || row['time'] is! String)
          continue;
        final time = DateTime.tryParse(row['time'] as String);
        if (time == null || time.isBefore(start) || time.isAfter(end)) continue;
        last = {'file': name, 'session': row['session'], 'seq': row['seq']};
      } on FormatException {
        // A process termination may leave the last line incomplete.
      }
    }
    if (last != null) return last;
  }
  return null;
}
