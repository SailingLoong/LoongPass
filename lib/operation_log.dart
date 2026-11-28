import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Process-local diagnostics. Callers supply code-owned event and target names.
/// A completed write is visible outside the process even if the embedder exits.
class OperationLog {
  OperationLog(this.directory, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  static OperationLog? current;
  static const retentionDays = 7;
  final Directory directory;
  final DateTime Function() _clock;
  final _session = '$pid-${DateTime.now().microsecondsSinceEpoch}';
  static final _logName = RegExp(
    r'^(?:operations-(\d{4}-\d{2}-\d{2})\.jsonl|crash-(\d{4}-\d{2}-\d{2})-[0-9a-fA-F-]{36}\.json)$',
  );
  RandomAccessFile? _file;
  Timer? _midnight;
  DateTime? _retryAfter;
  String? _day;
  String? page;
  int _sequence = 0;
  int _nextOperation = 0;

  static void startDesktop() {
    final env = Platform.environment;
    final home = Platform.isMacOS ? env['HOME'] : env['LOCALAPPDATA'];
    if (home == null || (!Platform.isMacOS && !Platform.isWindows)) return;
    final dir = Platform.isMacOS
        ? p.join(home, 'Library', 'Logs', 'LoongPass')
        : p.join(home, 'LoongPass', 'Logs');
    current = OperationLog(Directory(dir))
      ..record(
        'app.start',
        target: const String.fromEnvironment(
          'LOONGPASS_BUILD',
          defaultValue: 'local',
        ),
      );
  }

  static Future<T> trace<T>(
    String category,
    String target,
    Future<T> Function() action,
  ) async {
    final log = current;
    if (log == null) return action();
    final span = log.begin(category, target);
    try {
      final result = await action();
      log.finish(category, target, span, ok: true);
      return result;
    } catch (_) {
      log.finish(category, target, span, ok: false);
      rethrow;
    }
  }

  ({int id, Stopwatch timer}) begin(String category, String target) {
    final span = (id: ++_nextOperation, timer: Stopwatch()..start());
    record('$category.start', target: target, op: span.id);
    return span;
  }

  void finish(
    String category,
    String target,
    ({int id, Stopwatch timer}) span, {
    required bool ok,
  }) {
    record(
      ok ? '$category.ok' : '$category.error',
      target: target,
      op: span.id,
      elapsed: span.timer.elapsedMilliseconds,
    );
  }

  void recordError(String event, Object error, StackTrace? stack) {
    final frames = <String>[];
    if (stack != null) {
      for (final line in stack.toString().split('\n')) {
        if (frames.length >= 64) break;
        final match = RegExp(r'^#\d+\s+').firstMatch(line);
        if (match == null) continue;
        final frame = line.substring(match.end);
        final name = frame.split(' (').first;
        final safeName = RegExp(r'^[\w.$<>:= +\-]+$').hasMatch(name)
            ? name
            : 'frame';
        final location = RegExp(r'\(((?:package:|dart:)[\w./:-]+)\)\s*$')
            .firstMatch(frame);
        frames.add(location == null ? safeName : '$safeName (${location[1]})');
      }
    }
    record(event, target: error.runtimeType.toString(), frames: frames);
  }

  void record(
    String event, {
    String? target,
    int? op,
    int? elapsed,
    int? x,
    int? y,
    List<String>? frames,
  }) {
    final now = _clock().toLocal();
    if (_retryAfter?.isAfter(now) ?? false) return;
    try {
      final day = _date(now);
      if (_day != day) _rotate(day, now);
      _file!.writeStringSync(
        '${jsonEncode({'time': now.toUtc().toIso8601String(), 'pid': pid, 'session': _session, 'seq': ++_sequence, 'event': event, if (page != null) 'page': page, if (target != null) 'target': target, if (op != null) 'op': op, if (elapsed != null) 'durationMs': elapsed, if (x != null) 'x': x, if (y != null) 'y': y, if (frames != null) 'stack': frames})}\n',
      );
    } on IOException {
      // Diagnostics must remain independent of user operations and retries.
      close();
      _retryAfter = now.add(const Duration(minutes: 1));
    }
  }

  static String _date(DateTime day) => day.toIso8601String().substring(0, 10);

  void _rotate(String day, DateTime now) {
    close();
    if (FileSystemEntity.isLinkSync(directory.path)) {
      throw const FileSystemException('Log directory is a link');
    }
    directory.createSync(recursive: true);
    if (Platform.isMacOS &&
        Process.runSync('/bin/chmod', ['700', directory.path]).exitCode != 0) {
      throw const FileSystemException('Private log directory unavailable');
    }
    final cutoff = _date(
      DateTime(now.year, now.month, now.day - retentionDays + 1),
    );
    for (final entry in directory.listSync(followLinks: false)) {
      final match = _logName.firstMatch(p.basename(entry.path));
      if (entry is File &&
          match != null &&
          (match[1] ?? match[2])!.compareTo(cutoff) < 0) {
        try {
          entry.deleteSync();
        } on PathNotFoundException {
          // A second instance may have already removed this expired segment.
        }
      }
    }
    final path = p.join(directory.path, 'operations-$day.jsonl');
    if (FileSystemEntity.isLinkSync(path))
      throw const FileSystemException('Log file is a link');
    _file = File(path).openSync(mode: FileMode.writeOnlyAppend);
    _day = day;
    final next = DateTime(now.year, now.month, now.day + 1);
    _midnight = Timer(next.difference(now), () => record('log.rotate'));
  }

  Future<bool> openFolder() async {
    record('ui.openLogFolder');
    try {
      if (!directory.existsSync()) return false;
      if (Platform.isWindows) {
        await Process.start('explorer.exe', [
          directory.path,
        ], mode: ProcessStartMode.detached);
        return true;
      }
      return (await Process.run('/usr/bin/open', [directory.path])).exitCode ==
          0;
    } on IOException {
      return false;
    }
  }

  void close() {
    _midnight?.cancel();
    _midnight = null;
    try {
      _file?.closeSync();
    } on IOException {
      // Closing a failed sink must not escape into the application.
    }
    _file = null;
    _day = null;
  }
}
