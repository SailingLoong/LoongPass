import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/macos_crash_reports.dart';

void main() {
  test('imports only our recent Apple reports, retaining frames and correlation without private fields', () async {
    final tmp = Directory.systemTemp.createTempSync('loongpass-ips-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final output = Directory('${tmp.path}/logs')..createSync();
    const id = '12345678-1234-1234-1234-123456789abc';
    void report(String day, String bundle, String incident) {
      File('${tmp.path}/LoongPass-$day-080000.ips').writeAsStringSync(
        [
          jsonEncode({
            'bundleID': bundle,
            'incident_id': incident,
            'app_name': 'LoongPass',
            'build_version': '62',
            'timestamp': '$day 08:00:00.00',
          }),
          jsonEncode({
            'pid': 987,
            'procLaunch': '$day 07:00:00.00',
            'faultingThread': 0,
            'exception': {'type': 'EXC_BAD_ACCESS'},
            'procPath': '/Users/SECRET/LoongPass',
            'threads': [
              {
                'frames': [
                  {
                    'imageIndex': 0,
                    'imageOffset': 123,
                    'symbol': 'FlutterTextField frame',
                  },
                ],
              },
            ],
            'usedImages': [
              {
                'name': 'FlutterMacOS',
                'uuid': id,
                'path': '/Users/SECRET/FlutterMacOS',
              },
            ],
          }),
        ].join('\n'),
      );
    }

    report('2026-11-27', 'ours', id);
    report('2026-11-26', 'other', '02345678-1234-1234-1234-123456789abc');
    report('2026-11-20', 'ours', '22345678-1234-1234-1234-123456789abc');
    File('${tmp.path}/LoongPass-2026-11-28-120000.ips')
        .writeAsStringSync('{partial');
    File('${output.path}/operations-2026-11-27.jsonl').writeAsStringSync(
      [
        for (final item in [
          ('06:59', 987, 6),
          ('07:01', 987, 7),
          ('07:02', 13, 8),
          ('08:01', 987, 9),
        ])
          jsonEncode({
            'time': '2026-11-27T${item.$1}:00',
            'pid': item.$2,
            'seq': item.$3,
            'session': 'test-session',
          }),
        '{incomplete',
      ].join('\n'),
    );
    for (var run = 0; run < 2; run++) {
      await importMacCrashReports(tmp, output, 'ours', DateTime(2026, 11, 28));
    }
    final saved =
        (output
                .listSync()
                .whereType<File>()
                .where((file) => file.path.endsWith('.json'))
                .single)
            .readAsStringSync();
    final data = jsonDecode(saved);
    expect(data['pid'], 987);
    expect(data['lastOperation'], {
      'file': 'operations-2026-11-27.jsonl',
      'seq': 7,
      'session': 'test-session',
    });
    expect(data['build'], '62');
    expect(data['incident'], id);
    expect(data['stack'].single, {
      'image': 'FlutterMacOS',
      'uuid': id,
      'offset': 123,
      'symbol': 'FlutterTextField frame',
    });
    expect(saved, isNot(contains('SECRET')));
  });
}
