import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/pinned_bun.dart';

void main() {
  test(
    'an unverified download is rejected before extraction or execution',
    () async {
      final root = await Directory.systemTemp.createTemp('loongpass-bun-');
      try {
        await expectLater(
          PinnedBun.installArchive(
            root.path,
            'bun-test',
            [1, 2, 3],
            '90987a3a16d7db556d886ac3d551e7b6d3edf0a1cf43acaed622e8676be1d12f',
          ),
          throwsA(isA<FormatException>()),
        );
        expect(await root.list().toList(), isEmpty);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
