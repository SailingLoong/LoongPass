import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/operation_channel.dart';
import '../lib/operation_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late OperationLog log;
  var now = DateTime(2026, 11, 28, 23, 59);
  List<Map<String, dynamic>> rows(File file) => file
      .readAsLinesSync()
      .map((line) => jsonDecode(line) as Map<String, dynamic>)
      .toList();

  setUp(() {
    dir = Directory.systemTemp.createTempSync('loongpass-operations-');
    now = DateTime(2026, 11, 28, 23, 59);
    log = OperationLog(dir, clock: () => now);
    OperationLog.current = log;
  });

  tearDown(() {
    OperationLog.current = null;
    log.close();
    dir.deleteSync(recursive: true);
  });

  test('rolls on midnight and restart, keeping seven dated logs and unrelated files', () {
    File file(String name) => File('${dir.path}/$name');
    for (final day in ['20', '21', '22']) {
      file('operations-2026-11-$day.jsonl').writeAsStringSync('{}\n');
    }
    final unrelated = file('my-2026-11-01.jsonl')..createSync();
    log.record('app.start');
    expect(file('operations-2026-11-21.jsonl').existsSync(), isFalse);
    expect(file('operations-2026-11-22.jsonl').existsSync(), isTrue);
    now = DateTime(2026, 11, 29);
    log.record('ui.press', target: 'button');
    expect(file('operations-2026-11-22.jsonl').existsSync(), isFalse);
    log.close();
    final reopened = OperationLog(dir, clock: () => now);
    reopened.record('app.start');
    reopened.close();
    final next = rows(file('operations-2026-11-29.jsonl'));
    expect(next.map((r) => r['event']), ['ui.press', 'app.start']);
    expect(rows(file('operations-2026-11-28.jsonl')).single['pid'], pid);
    expect(unrelated.existsSync(), isTrue);
  });

  test('channel operations keep start and outcome with no payload, reply or exception text', () async {
    const channel = OperationMethodChannel('diagnostic-test');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'fail')
        throw PlatformException(code: 'secret-failure');
      return 'secret-result';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect(
      await channel.invokeMethod<String>('read', 'secret-input'),
      'secret-result',
    );
    await expectLater(
      channel.invokeMethod<void>('fail'),
      throwsA(isA<PlatformException>()),
    );
    final file = dir.listSync().whereType<File>().single;
    final entries = rows(file);
    expect(entries.map((r) => r['event']), [
      'native.start',
      'native.ok',
      'native.start',
      'native.error',
    ]);
    expect(entries.first['op'], entries[1]['op']);
    expect(entries[2]['op'], entries.last['op']);
    expect(entries.first['op'], isNot(entries.last['op']));
    expect(file.readAsStringSync(), isNot(contains('secret-')));
  });

  test('Dart errors retain stack symbols and package positions without exception contents', () {
    log.recordError(
      'flutter.error',
      StateError('secret-message'),
      StackTrace.fromString(
        '#0      Catalog.open (package:loongpass/catalog.dart:10:8)\n'
        '#1      main (file:///Users/SECRET/main.dart:3:2)',
      ),
    );
    final file = dir.listSync().whereType<File>().single;
    expect(rows(file).single['stack'], [
      'Catalog.open (package:loongpass/catalog.dart:10:8)',
      'main',
    ]);
    expect(file.readAsStringSync(), isNot(contains('secret-message')));
    expect(file.readAsStringSync(), isNot(contains('SECRET')));
  });

  test(
    'an unavailable log directory does not change an operation outcome',
    () async {
      final file = File('${dir.path}/file')..createSync();
      final unavailable = OperationLog(Directory(file.path));
      OperationLog.current = unavailable;
      expect(await OperationLog.trace('plugin', 'load', () async => 42), 42);
      unavailable.close();
    },
  );
}
