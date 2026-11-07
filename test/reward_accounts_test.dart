import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import '../lib/rewards/reward_accounts.dart';
import '../lib/rewards/reward_provider.dart';
import 'reward_test_support.dart';

void main() {
  late MemoryStore store;
  late Provider first, second;
  DateTime clock = DateTime.utc(2026, 11, 7, 15, 59);
  final owners = <RewardAccounts>[];
  RewardAccounts open() {
    final value = RewardAccounts(
      store: store,
      providers: [first, second],
      transportFor: (_) => NoNetwork(),
      now: () => clock,
    );
    owners.add(value);
    return value;
  }

  Future<RewardAccounts> signedIn() async {
    final owner = open();
    await owner.restore();
    await owner.beginLogin(first.id);
    expect(await owner.completeLogin(), isTrue);
    return owner;
  }

  setUp(() {
    store = MemoryStore();
    first = Provider('one');
    second = Provider('two');
    clock = DateTime.utc(2026, 11, 7, 15, 59);
  });
  tearDown(() {
    for (final owner in owners) {
      owner.dispose();
    }
    owners.clear();
  });

  test(
    'confirmed daily receipt and absolute balance survive restart without a duplicate claim',
    () async {
      final owner = await signedIn();
      await owner.claim('one', first.identity);
      final account = owner.accountsFor('one').single;
      expect(account.receipt!.amount, 100);
      expect(account.receipt!.unit, '积分');
      expect(account.day, '2026-11-07');
      expect(account.credits!.totalRemaining, 125.5);
      expect(account.credits!.withoutExpiry, 25.5);
      expect(account.credits!.expiring.single.remaining, 100);
      final restored = open();
      await restored.restore();
      await restored.claim('one', first.identity);
      expect(first.claims, 1);
      expect(restored.accountsFor('one').single.receipt!.amount, 100);
    },
  );

  test(
    'lost receipt is not replayed after restart or same-account reauthorization',
    () async {
      first.loseReply = true;
      final owner = await signedIn();
      await owner.claim('one', first.identity);
      expect(owner.accountsFor('one').single.outcome, 'unknown');
      first.token = 'synthetic-rotated-token';
      first.login = null;
      final restored = open();
      await restored.restore();
      await restored.beginLogin('one');
      await restored.completeLogin();
      await restored.claim('one', first.identity);
      expect(first.claims, 1);
      expect(restored.accountsFor('one').length, 1);
      expect(restored.accountsFor('one').single.outcome, 'unknown');
      first.inspected = RewardState.already;
      await restored.claim('one', first.identity);
      expect(first.claims, 1);
      expect(restored.accountsFor('one').single.outcome, 'already');
      expect(restored.accountsFor('one').single.receipt, isNull);
    },
  );

  test('intent persistence failure prevents sending a claim', () async {
    final owner = await signedIn();
    store.failWrites = true;
    await expectLater(
      owner.claim('one', first.identity),
      throwsA(isA<RewardFailure>()),
    );
    expect(first.claims, 0);
  });

  test(
    'a persisted pending intent is never replayed even when final recording failed',
    () async {
      final owner = await signedIn();
      first.claimGate = Completer<void>();
      final pending = owner.claim('one', first.identity);
      while (first.claims == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      store.failWrites = true;
      first.claimGate!.complete();
      await expectLater(pending, throwsA(isA<RewardFailure>()));
      store.failWrites = false;
      final restored = open();
      await restored.restore();
      await restored.claim('one', first.identity);
      expect(first.claims, 1);
      expect(restored.accountsFor('one').single.outcome, 'unknown');
    },
  );

  test(
    'same official user ID in different providers stays isolated and disabled accounts are skipped',
    () async {
      final owner = await signedIn();
      await owner.beginLogin('two');
      await owner.completeLogin();
      await owner.setAutomatic('one', first.identity, false);
      await owner.tick();
      expect(first.claims, 0);
      expect(second.claims, 1);
      expect(owner.accountsFor('one').single.automatic, isFalse);
      expect(owner.accountsFor('two').single.receipt!.amount, 100);
    },
  );

  test(
    'reading snapshots does not perform I/O and next Shanghai day can claim independently',
    () async {
      final owner = await signedIn();
      final reads = first.reads;
      owner.accountsFor('one');
      owner.accountsFor('one');
      expect(first.reads, reads);
      await owner.claim('one', first.identity);
      clock = DateTime.utc(2026, 11, 7, 16, 1);
      await owner.claim('one', first.identity);
      expect(first.claims, 2);
      expect(owner.accountsFor('one').single.day, '2026-11-08');
    },
  );

  test('cancelling authorization discards an in-flight result', () async {
    final owner = open();
    await owner.restore();
    final flow = Login(null)..wait = Completer<RewardSession?>();
    first.login = flow;
    await owner.beginLogin('one');
    final pending = owner.completeLogin();
    owner.cancelLogin();
    flow.wait!.complete(
      RewardSession(
        identity: 'cancelled-user',
        label: 'Cancelled',
        credentials: {'token': 'synthetic-cancelled'},
      ),
    );
    await pending;
    expect(owner.accountsFor('one'), isEmpty);
    expect(flow.cancelled, isTrue);
  });

  test('delete then re-add keeps the daily intent tombstone', () async {
    final owner = await signedIn();
    first.loseReply = true;
    await owner.claim('one', first.identity);
    await owner.remove('one', first.identity);
    expect(owner.accountsFor('one'), isEmpty);
    first.login = null;
    await owner.beginLogin('one');
    await owner.completeLogin();
    await owner.claim('one', first.identity);
    expect(first.claims, 1);
    expect(owner.accountsFor('one').single.outcome, 'unknown');
  });

  test(
    'one account authorization failure remains visible after another account succeeds',
    () async {
      final owner = await signedIn();
      await owner.beginLogin('two');
      await owner.completeLogin();
      first.failBalance = true;
      await owner.tick();
      expect(owner.accountsFor('one').single.needsAttention, isTrue);
      expect(owner.accountsFor('two').single.needsAttention, isFalse);
      expect(second.claims, 1);
    },
  );

  test(
    'an explicit rejection permits same-day retry after reauthorization',
    () async {
      final owner = await signedIn();
      first.rejectClaim = true;
      await expectLater(
        owner.claim('one', first.identity),
        throwsA(isA<RewardRejected>()),
      );
      expect(owner.accountsFor('one').single.outcome, 'rejected');
      first.rejectClaim = false;
      first.login = null;
      await owner.beginLogin('one');
      await owner.completeLogin();
      await owner.claim('one', first.identity);
      expect(first.claims, 2);
      expect(owner.accountsFor('one').single.receipt!.amount, 100);
    },
  );
}
