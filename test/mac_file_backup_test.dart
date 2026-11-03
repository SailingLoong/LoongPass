import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/mac_file_backup.dart';
import '../lib/zcode_accounts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.sailingloong.loongpass/files');
  const backup = MacFileBackup();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temp;
  late Directory root;
  late File source;
  late List<String> calls;
  Object? selection;
  bool failRelease = false;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('loongpass-bridge-test-');
    temp = Directory(await temp.resolveSymbolicLinks());
    root = await temp.createTemp('private-');
    expect((await Process.run('chmod', ['700', root.path])).exitCode, 0);
    source = File('${temp.path}/chosen.json');
    await source.writeAsString('{"sample":"synthetic-only"}\n');
    calls = [];
    selection = {'sourcePath': source.path, 'privateRoot': root.path};
    failRelease = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'chooseBackupSource') {
        if (selection is Exception) throw selection!;
        return selection;
      }
      if (call.method == 'releaseBackupSource' && failRelease) {
        throw PlatformException(
          code: 'synthetic_failure',
          message: 'DO_NOT_SHOW',
        );
      }
      return null;
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await temp.delete(recursive: true);
  });

  test('cancel selection performs no backup or unnecessary release', () async {
    selection = null;
    expect(await backup.selectAndBackup(), isNull);
    expect(calls, ['chooseBackupSource']);
    expect(await root.list().toList(), isEmpty);
  });

  test(
    'chosen synthetic file goes through real strict backup and releases scope',
    () async {
      final saved = (await backup.selectAndBackup())!;
      expect(await File(saved).readAsBytes(), await source.readAsBytes());
      expect(calls, ['chooseBackupSource', 'releaseBackupSource']);
      expect(await source.readAsString(), '{"sample":"synthetic-only"}\n');
    },
  );

  test('invalid source still releases scope and leaves no backup', () async {
    await source.writeAsString('{"a":1}');
    await expectLater(
      backup.selectAndBackup(),
      throwsA(
        isA<AccountFailure>().having((e) => e.code, 'code', 'InvalidDocument'),
      ),
    );
    expect(calls, ['chooseBackupSource', 'releaseBackupSource']);
    expect(await root.list().toList(), isEmpty);
  });

  test('malformed native selection is rejected and released', () async {
    selection = {'sourcePath': 123, 'privateRoot': root.path};
    await expectLater(
      backup.selectAndBackup(),
      throwsA(
        isA<AccountFailure>().having((e) => e.code, 'code', 'InvalidSelection'),
      ),
    );
    expect(calls, ['chooseBackupSource', 'releaseBackupSource']);
    expect(await root.list().toList(), isEmpty);
  });

  test(
    'native picker errors expose no file path or underlying error text',
    () async {
      selection = PlatformException(code: 'failed', message: 'DO_NOT_SHOW');
      await expectLater(
        backup.selectAndBackup(),
        throwsA(
          isA<AccountFailure>().having(
            (e) => e.toString(),
            'sanitized',
            'NativeBackupUnavailable',
          ),
        ),
      );
      expect(calls, ['chooseBackupSource']);
    },
  );

  test(
    'native private-directory refusal remains useful and sanitized',
    () async {
      selection = PlatformException(
        code: 'PrivateDirectoryRequired',
        message: 'DO_NOT_SHOW',
      );
      await expectLater(
        backup.selectAndBackup(),
        throwsA(
          isA<AccountFailure>().having(
            (e) => e.toString(),
            'sanitized',
            'PrivateDirectoryRequired',
          ),
        ),
      );
      expect(calls, ['chooseBackupSource']);
    },
  );

  test(
    'failed scope release does not claim fully successful completion',
    () async {
      failRelease = true;
      await expectLater(
        backup.selectAndBackup(),
        throwsA(
          isA<AccountFailure>().having(
            (e) => e.code,
            'code',
            'BackupSavedCleanupFailed',
          ),
        ),
      );
      expect(await root.list().toList(), hasLength(1));
      expect(await source.readAsString(), '{"sample":"synthetic-only"}\n');
    },
  );

  test('reveal uses native Finder method without a shell', () async {
    final saved = (await backup.selectAndBackup())!;
    await backup.reveal(saved);
    expect(calls.last, 'revealBackup');
  });
}
