import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../tool/workbuddy_journal_checks.dart' as fixture;
import '../lib/workbuddy_claim.dart';

void main() {
  test(
    'journal retains last settled success when next day is pending',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'loongpass-receipt-test-',
      );
      final root = Directory(await temp.resolveSymbolicLinks());
      if (!Platform.isWindows) {
        await Process.run('chmod', ['700', root.path]);
      }
      addTearDown(() => temp.delete(recursive: true));
      final f = fixture.Fixture(root);
      final journal = f.open();
      await journal.compareAndSet(fixture.subject.key, null, fixture.row());
      await journal.compareAndSet(
        fixture.subject.key,
        0,
        fixture.row(revision: 1, receipt: WorkBuddyState.claimed, expected: 20),
      );
      await journal.compareAndSet(
        fixture.subject.key,
        1,
        fixture.row(
          revision: 2,
          receipt: WorkBuddyState.claimed,
          expected: 20,
          settled: WorkBuddyState.claimed,
          credited: 20,
        ),
      );
      await journal.compareAndSet(
        fixture.subject.key,
        2,
        fixture.row(revision: 3, date: '2026-11-05'),
      );
      final previous = await f.open().latestSuccessful(fixture.subject.key);
      expect(previous?.credited, 20);
      expect(previous?.day, '2026-11-04');
      expect(
        (await journal.read(fixture.subject.key))?.settled,
        WorkBuddyState.unconfirmed,
      );
    },
  );
}
