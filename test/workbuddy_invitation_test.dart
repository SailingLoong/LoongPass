import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../lib/workbuddy_invitation.dart';

void main() {
  test(
    'failed settings read stays unavailable until a successful retry',
    () async {
      var fail = true;
      final settings = WorkBuddyInvitation(
        read: () async {
          if (fail) throw StateError('synthetic read failure');
          return 'saved-code';
        },
      );
      addTearDown(settings.dispose);
      await settings.load();
      expect(settings.ready, isFalse);
      await expectLater(settings.save('other-code'), throwsStateError);
      fail = false;
      await settings.load();
      expect(settings.ready, isTrue);
      expect(settings.url.queryParameters['inviteCode'], 'saved-code');
    },
  );

  test('blank settings produce the approved official invitation URL', () async {
    final settings = WorkBuddyInvitation(read: () async => null);
    addTearDown(settings.dispose);
    await settings.load();
    expect(
      settings.url.toString(),
      'https://www.workbuddy.cn/events/invite/?inviteCode=3wu5mr8ye2b0',
    );
    expect(settings.overrideCode, isEmpty);
  });

  test(
    'saved override survives reopening and clearing restores default',
    () async {
      String? stored;
      WorkBuddyInvitation open() => WorkBuddyInvitation(
        read: () async => stored,
        write: (value) async => stored = value,
      );
      final settings = open();
      addTearDown(settings.dispose);
      await settings.load();
      await settings.save('  another-code_12  ');
      final restored = open();
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.url.queryParameters['inviteCode'], 'another-code_12');
      await restored.save('  ');
      final reset = open();
      addTearDown(reset.dispose);
      await reset.load();
      expect(reset.url.queryParameters['inviteCode'], '3wu5mr8ye2b0');
    },
  );

  test('failed save keeps the previously saved invitation', () async {
    final settings = WorkBuddyInvitation(
      read: () async => 'saved-code',
      write: (_) async => throw StateError('synthetic storage failure'),
    );
    addTearDown(settings.dispose);
    await settings.load();
    await expectLater(settings.save('replacement'), throwsStateError);
    expect(settings.url.queryParameters['inviteCode'], 'saved-code');
  });

  test(
    'an earlier slow save cannot replace the later saved override',
    () async {
      final gate = Completer<void>();
      String? stored;
      final settings = WorkBuddyInvitation(
        write: (value) async {
          if (value == 'first') await gate.future;
          stored = value;
        },
      );
      addTearDown(settings.dispose);
      final first = settings.save('first');
      final second = settings.save('second');
      gate.complete();
      await Future.wait([first, second]);
      expect(stored, 'second');
      expect(settings.url.queryParameters['inviteCode'], 'second');
    },
  );
}
