@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/zcode_accounts.dart';
import '../lib/zcode_auth_file.dart';

void main() {
  late Directory temp;
  late Directory backups;
  late File source;
  final identity = AccountIdentity('synthetic-local', 'zai', 'target');
  final currentIdentity = AccountIdentity('synthetic-local', 'zai', 'current');
  final fields = <String, String>{
    'oauth:active_provider': 'zai',
    'oauth:zai:access_token': 'synthetic-access',
    'oauth:zai:user_info': 'synthetic-user',
    'unrelated': 'must survive exactly',
  };
  Matcher failure(String code) =>
      isA<AccountFailure>().having((e) => e.code, 'code', code);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('loongpass-test-');
    temp = Directory(await temp.resolveSymbolicLinks());
    backups = await temp.createTemp('private-');
    // Only synthetic temporary test directories; production accepts an already
    // private app directory and never changes OS permissions.
    if (!Platform.isWindows) {
      final mode = await Process.run('chmod', ['700', backups.path]);
      expect(mode.exitCode, 0);
    }
    source = File('${temp.path}/auth.json');
    await source.writeAsString(jsonEncode(fields));
  });
  tearDown(() async => temp.delete(recursive: true));

  test('backup preserves exact bytes, all fields, and source', () async {
    final raw = utf8.encode(
      ' {\n "unknown":"保留", "cipher":"enc:v1:opaque"\n}\n',
    );
    await source.writeAsBytes(raw);
    final saved = await ZcodeAuthFile.backup(source, backups);
    expect(await saved.readAsBytes(), raw);
    expect(await source.readAsBytes(), raw);
    expect(saved.path, isNot(source.path));
    expect((await backups.stat()).mode & 0x3f, 0);
  });

  test(
    'backup can be imported through existing seven-field switch core',
    () async {
      final saved = await ZcodeAuthFile.backup(source, backups);
      final snapshot = await ZcodeAuthFile.import(saved, identity);
      final current = {
        ...fields,
        'oauth:zai:access_token': 'current-synthetic',
      };
      final next = SwitchPlan.prepare(
        currentIdentity,
        current,
        snapshot,
      ).apply(current);
      expect(next['oauth:zai:access_token'], 'synthetic-access');
      expect(next['unrelated'], 'must survive exactly');
      expect(await source.readAsString(), jsonEncode(fields));
    },
  );

  test(
    'each backup is independent and never overwrites a previous backup',
    () async {
      final first = await ZcodeAuthFile.backup(source, backups);
      final original = await first.readAsBytes();
      await source.writeAsString(jsonEncode({...fields, 'extra': 'new'}));
      final second = await ZcodeAuthFile.backup(source, backups);
      expect(second.path, isNot(first.path));
      expect(await first.readAsBytes(), original);
      expect(await second.readAsBytes(), await source.readAsBytes());
    },
  );

  final invalidDocuments = <String, String>{
    'duplicate': '{"a":"first","a":"second"}',
    'escaped duplicate': r'{"a":"first","\u0061":"second"}',
    'number': '{"a":1}',
    'null': '{"a":null}',
    'nested': '{"a":{}}',
    'array': '[]',
    'trailing': '{} false',
    'trailing comma': '{"a":"b",}',
    'unclosed string': '{"a":"b}',
    'invalid escape': r'{"a":"\x20"}',
    'unpaired surrogate': r'{"a":"\ud800"}',
    'non JSON whitespace': '\u00a0{}',
    'UTF-8 BOM': '\ufeff{}',
  };
  for (final invalid in invalidDocuments.entries) {
    test(
      'rejects ${invalid.key} without altering source or leaving a backup',
      () async {
        await source.writeAsString(invalid.value);
        await expectLater(
          ZcodeAuthFile.backup(source, backups),
          throwsA(failure('InvalidDocument')),
        );
        expect(await source.readAsBytes(), utf8.encode(invalid.value));
        expect(await backups.list().toList(), isEmpty);
      },
    );
  }

  test('strict decoding rejects malformed UTF-8', () async {
    final raw = [0x7b, 0x22, 0xc0, 0xaf, 0x22, 0x3a, 0x22, 0x22, 0x7d];
    await source.writeAsBytes(raw);
    await expectLater(
      ZcodeAuthFile.backup(source, backups),
      throwsA(failure('InvalidDocument')),
    );
    expect(await source.readAsBytes(), raw);
  });

  test('raw size limit is enforced before copying', () async {
    await source.writeAsBytes(List.filled(4 * 1024 * 1024 + 1, 32));
    await expectLater(
      ZcodeAuthFile.backup(source, backups),
      throwsA(failure('DocumentTooLarge')),
    );
    expect(await backups.list().toList(), isEmpty);
  });

  test(
    'source change after backup write removes only the incomplete backup',
    () async {
      final changed = jsonEncode({
        ...fields,
        'oauth:zai:access_token': 'new-synthetic',
      });
      final changing = _ChangingFile(source, changed);
      await expectLater(
        ZcodeAuthFile.backup(changing, backups),
        throwsA(failure('SourceChanged')),
      );
      expect(await backups.list().toList(), isEmpty);
      expect(await source.readAsString(), changed);
    },
  );

  test(
    'missing required session fields reject import without secret diagnostics',
    () async {
      await source.writeAsString('{"secret":"SYNTHETIC_DO_NOT_LOG"}');
      try {
        await ZcodeAuthFile.import(source, identity);
        fail('expected missing-session rejection');
      } on AccountFailure catch (e) {
        expect(e.code, 'MissingSessionCredential');
        expect(e.toString(), isNot(contains('SYNTHETIC_DO_NOT_LOG')));
        expect(e.toString(), isNot(contains(source.path)));
      }
    },
  );

  test('escaped quotes and paired surrogate strings remain valid', () async {
    await source.writeAsString(
      jsonEncode({...fields, 'escaped"key': 'quote" slash\\ emoji😀'}),
    );
    final saved = await ZcodeAuthFile.backup(source, backups);
    expect(await saved.readAsBytes(), await source.readAsBytes());
  });

  test(
    'missing source returns a sanitized failure and creates nothing',
    () async {
      await source.delete();
      await expectLater(
        ZcodeAuthFile.backup(source, backups),
        throwsA(failure('InvalidFile')),
      );
      expect(await backups.list().toList(), isEmpty);
    },
  );

  test('missing destination is not automatically created', () async {
    final missing = Directory('${temp.path}/not-created');
    await expectLater(
      ZcodeAuthFile.backup(source, missing),
      throwsA(failure('PrivateDirectoryRequired')),
    );
    expect(await missing.exists(), isFalse);
  });

  test('source symlinks are rejected and targets remain untouched', () async {
    final link = Link('${temp.path}/link.json');
    await link.create(source.path);
    await expectLater(
      ZcodeAuthFile.backup(File(link.path), backups),
      throwsA(failure('InvalidFile')),
    );
    expect(await source.readAsString(), jsonEncode(fields));
  }, skip: Platform.isWindows);

  test(
    'symlink plus parent traversal cannot redirect a checked destination',
    () async {
      final public = await Directory('${temp.path}/public-target').create();
      final child = await Directory('${public.path}/child').create();
      final name = backups.path.split(Platform.pathSeparator).last;
      final redirected = await Directory('${public.path}/$name').create();
      final link = await Link('${temp.path}/alias').create(child.path);
      final alias = Directory('${link.path}/../$name');
      await expectLater(
        ZcodeAuthFile.backup(source, alias),
        throwsA(failure('PrivateDirectoryRequired')),
      );
      expect(await redirected.list().toList(), isEmpty);
      expect(await backups.list().toList(), isEmpty);
    },
    skip: Platform.isWindows,
  );

  test('destination symlinks are rejected', () async {
    final link = Link('${temp.path}/linked-root');
    await link.create(backups.path);
    await expectLater(
      ZcodeAuthFile.backup(source, Directory(link.path)),
      throwsA(failure('PrivateDirectoryRequired')),
    );
    expect(await backups.list().toList(), isEmpty);
  }, skip: Platform.isWindows);

  test('nonprivate destination is rejected without creating output', () async {
    final public = await Directory('${temp.path}/public').create();
    // Ordinary directory creation inherits umask; no permission changes in tests.
    if ((await public.stat()).mode & 0x3f == 0) return;
    await expectLater(
      ZcodeAuthFile.backup(source, public),
      throwsA(failure('PrivateDirectoryRequired')),
    );
    expect(await public.list().toList(), isEmpty);
  }, skip: Platform.isWindows);
}

// Uses a real temporary file, changing it precisely before the final re-read.
class _ChangingFile implements File {
  final File delegate;
  final String replacement;
  var reads = 0;
  _ChangingFile(this.delegate, this.replacement);
  @override
  String get path => delegate.path;
  @override
  Future<FileStat> stat() => delegate.stat();
  @override
  Stream<List<int>> openRead([int? start, int? end]) async* {
    if (++reads == 2) await delegate.writeAsString(replacement);
    yield* delegate.openRead(start, end);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
