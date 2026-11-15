import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/magpie_connection.dart';
import '../lib/plugin_accounts.dart';
import '../lib/plugin_model_service.dart';
import 'magpie_fixture.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('loongpass-bridge-');
    await File('${directory.path}/package.json').writeAsString(
      jsonEncode({
        'name': '@sailing-loong/magpie-bridge',
        'repository': {
          'url': 'git+https://github.com/SailingLoong/LoongPass.git',
        },
      }),
    );
  });
  tearDown(() => directory.delete(recursive: true));

  final grant = PluginModelGrant(
    PluginAccount(
      key: 'saved-account',
      facts: {'provider': 'zcode'},
      active: true,
      models: [],
    ),
    'synthetic-local-grant',
    true,
  );

  for (final failure in [
    null,
    'superseded',
    'missing-grant',
    'removed-grant',
  ]) {
    test(
      'explicit connection reconciles distributions with verification: $failure',
      () async {
        const npm = '@sailing-loong/magpie-bridge@0.2.1';
        const github = 'github:SailingLoong/LoongPass#main';
        const foreign = '@someone-else/loongpass';
        const unknownLocal = '/unrelated/local-plugin';
        final installed = <String>{npm, github, foreign, unknownLocal};
        final calls = <List<String>>[];
        var selected = false, saved = false, verified = false, removed = false;
        final connection = MagpieConnection(
          run: (args, {input}) async {
            calls.add(args);
            switch (args[1]) {
              case 'add':
                installed.add(directory.path);
              case 'use':
                expect(args, ['plugin', 'use', directory.path, 'loongpass']);
                selected = true;
              case 'login':
                expect(
                  selected,
                  isTrue,
                  reason: 'Choose the bundled owner before saving its grants',
                );
                saved = true;
              case 'rm':
                expect(
                  verified,
                  isTrue,
                  reason: 'Retire sources only after owner and grants were verified',
                );
                expect([npm, github], contains(args[2]));
                installed.remove(args[2]);
                removed = true;
              case 'list':
                final owner = selected && failure != 'superseded'
                    ? directory.path
                    : npm;
                final ids =
                    saved &&
                        failure != 'missing-grant' &&
                        !(removed && failure == 'removed-grant')
                    ? ['saved-account']
                    : <String>[];
                final listing = magpiePluginList(ids);
                listing['plugins'] = [
                  for (final spec in installed) {'spec': spec},
                ];
                listing['loaded'][0]['spec'] = owner;
                listing['providers'][0]['spec'] = owner;
                if (saved && owner == directory.path && ids.isNotEmpty)
                  verified = true;
                return jsonEncode(listing);
            }
            return '';
          },
        );
        final result = connection.connect(
          directory.path,
          Uri.parse('http://127.0.0.1:3426'),
          [grant],
        );
        if (failure == null) {
          await result;
          expect(installed, {directory.path, foreign, unknownLocal});
          expect(calls.where((a) => a[1] == 'rm'), [
            ['plugin', 'rm', npm],
            ['plugin', 'rm', github],
          ]);
          expect(calls.last, ['plugin', 'list', '--json']);
        } else {
          await expectLater(result, throwsStateError);
          if (failure != 'removed-grant') {
            expect(calls.any((a) => a[1] == 'rm'), isFalse);
          }
        }
        expect(
          calls.expand((a) => a),
          isNot(contains('synthetic-local-grant')),
        );
      },
    );
  }
}
