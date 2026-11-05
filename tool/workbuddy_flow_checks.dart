import 'dart:async';
import '../lib/workbuddy_account_flow.dart';
import '../lib/workbuddy_api.dart';
import '../lib/workbuddy_claim.dart';

void check(bool condition, String why) {
  if (!condition) throw StateError(why);
}

// Only the network and durable-storage boundaries are synthetic. The API,
// profile verification, controller, bridge and transaction core are real.
class MemoryStore implements WorkBuddyAttemptStore {
  WorkBuddyAttempt? row;
  bool deny = false;
  @override Future<WorkBuddyAttempt?> read(String key) async => row;
  @override Future<bool> compareAndSet(String key, int? revision,
      WorkBuddyAttempt next) async {
    if (deny || row?.revision != revision) return false;
    row = next;
    return true;
  }
}

class SyntheticExchange implements WorkBuddyExchange {
  int requests = 0, posts = 0;
  bool pending = false, loseReceipt = false, failProfile = false;
  Completer<void>? waitState, waitToken, waitClaim, waitProfile;
  void Function()? afterClaim;
  @override Future<Map<String, Object?>> send(
      WorkBuddyRequest request, bool Function() admitted) async {
    check(admitted(), 'owner must be current before exchange');
    requests++;
    final path = request.uri.path;
    if (path.endsWith('/auth/state')) {
      await waitState?.future;
      return {'code': 0, 'data': {'state': 'test-state',
        'url': 'https://www.codebuddy.cn/authorize?state=test-state'}};
    }
    if (path.endsWith('/auth/token')) {
      await waitToken?.future;
      return pending ? {'code': 11217} : {'code': 0, 'data': {
        'accessToken': 'synthetic-secret', 'domain': 'www.workbuddy.cn'}};
    }
    if (path.endsWith('/plugin/account')) {
      await waitProfile?.future;
      if (failProfile) throw const WorkBuddyApiFailure('OutcomeUnknown');
      return {'code': 0, 'data': {'uid': 'synthetic-user', 'type':'personal',
        'domain': 'www.workbuddy.cn'}};
    }
    if (path.endsWith('/daily-checkin')) {
      check(request.method == 'POST', 'claim is one POST');
      check(admitted(), 'gate must still be current at dispatch');
      posts++;
      afterClaim?.call();
      await waitClaim?.future;
      if (loseReceipt) throw StateError('synthetic-secret must not leak');
      return {'code': 0, 'credit': 20};
    }
    check(path.endsWith('/checkin-activity-status'), 'unexpected endpoint');
    return {'code': 0, 'data': {'today_checked_in': posts > 0, 'active': true}};
  }
}

WorkBuddyAccountFlow owner(SyntheticExchange e, MemoryStore s, {
  String generation = 'owner-1', bool Function()? current, bool dependencies = true,
  double? before = 10, double? after = 30,
}) => WorkBuddyAccountFlow(exchange: e, ownerGeneration: generation,
  isOwnerCurrent: current ?? () => true,
  store: dependencies ? s : null,
  readCompleteBalance: dependencies ? (subject) async =>
    (subject: subject, totalRemaining: e.posts == 0 ? before : after) : null,
  now: () => DateTime.utc(2026, 11, 4, 4));

Future<void> login(WorkBuddyAccountFlow f) async {
  check(await f.begin() != null, 'authorization URL should be returned');
  await f.poll();
  check(f.uid == 'synthetic-user', 'must use profile-verified UID');
}

Future<void> main() async {
  var passed = 0, failed = 0;
  Future<void> test(String name, Future<void> Function() body) async {
    try { await body(); passed++; print('PASS $name'); }
    catch (error) { failed++; print('FAIL $name: $error'); }
  }

  await test('render owner initialization sends no traffic', () async {
    final e = SyntheticExchange(), s = MemoryStore();
    final f = owner(e, s);
    check(e.requests == 0 && !f.busy && !f.loginPending && !f.canClaim,
      'construction must not perform auth or enable claim');
  });
  await test('authorization pending then profile verified remains memory only', () async {
    final e = SyntheticExchange()..pending = true, s = MemoryStore();
    final f = owner(e, s);
    check((await f.begin())?.host == 'www.workbuddy.cn', 'validated browser URL');
    await f.poll();
    check(f.loginPending && f.uid == null && !f.canClaim, 'pending is not an account');
    e.pending = false;
    await f.poll();
    check(f.uid == 'synthetic-user' && f.domain == 'www.workbuddy.cn', 'verified identity');
    check(!f.loginPending && f.canClaim && s.row == null, 'no claim/persistence on login');
  });
  await test('duplicate begin shares no second request', () async {
    final e = SyntheticExchange()..waitState = Completer<void>();
    final f = owner(e, MemoryStore());
    final first = f.begin();
    check(f.busy, 'begin marks busy synchronously');
    check(await f.begin() == null && e.requests == 1, 'duplicate begin ignored');
    e.waitState!.complete(); await first;
  });
  await test('temporary profile failure retains the received grant for retry', () async {
    final e = SyntheticExchange()..failProfile = true;
    final f = owner(e, MemoryStore());
    await f.begin();
    await f.poll();
    check(f.loginPending && f.uid == null, 'received grant must remain pending');
    e.failProfile = false;
    await f.poll();
    check(f.uid == 'synthetic-user' && e.requests == 4,
      'retry verifies the retained token without another token request');
    check(e.posts == 0, 'authorization retry cannot send check-in');
    f.close();
  });
  await test('cancel during state request discards late authorization', () async {
    final e = SyntheticExchange()..waitState = Completer<void>();
    final f = owner(e, MemoryStore()); final first = f.begin();
    f.cancelLogin(); e.waitState!.complete();
    check(await first == null && !f.loginPending && !f.busy, 'late authorization dropped');
    await f.poll(); check(e.requests == 1, 'cancelled flow cannot poll');
  });
  await test('cancel while token awaits cannot admit profile account', () async {
    final e = SyntheticExchange()..waitToken = Completer<void>();
    final f = owner(e, MemoryStore()); await f.begin();
    final poll = f.poll(); f.cancelLogin(); e.waitToken!.complete(); await poll;
    check(f.uid == null && e.requests == 2 && !f.canClaim, 'no late profile or account');
  });
  await test('missing required durable owner disables claim', () async {
    final e = SyntheticExchange(), s = MemoryStore();
    final f = owner(e, s, dependencies: false); await login(f);
    check(!f.canClaim, 'missing owner is unavailable');
    await f.claim(); check(e.posts == 0 && s.row == null, 'must not bypass missing owner');
  });
  await test('complete balance and receipt corroborate one credited result', () async {
    final e = SyntheticExchange(), s = MemoryStore(); final f = owner(e, s);
    await login(f); await f.claim();
    check(f.result?.state == WorkBuddyState.claimed && f.result?.credited == 20,
      'receipt and observed increase must corroborate');
    await f.claim(); check(e.posts == 1, 'journal prevents duplicate claim');
  });
  await test('duplicate claim while awaiting sends only once', () async {
    final e = SyntheticExchange()..waitClaim = Completer<void>();
    final f = owner(e, MemoryStore()); await login(f);
    final first = f.claim();
    while (e.posts == 0) { await Future<void>.delayed(Duration.zero); }
    await f.claim(); check(e.posts == 1 && f.busy, 'duplicate blocked');
    e.waitClaim!.complete(); await first;
  });
  await test('unknown receipt keeps durable intent across reauthorization', () async {
    final e = SyntheticExchange()..loseReceipt = true, s = MemoryStore();
    final f = owner(e, s); await login(f); await f.claim();
    final intent = s.row;
    check(f.result?.state == WorkBuddyState.unconfirmed && !f.canClaim,
      'unknown must remain unknown and not offer retry');
    await f.refreshStatus(); await f.claim();
    check(f.result?.state == WorkBuddyState.unconfirmed && e.posts == 1 &&
      identical(intent, s.row), 'status must not claim success or clear intent');
    f.close();
    final next = owner(e, s, generation: 'owner-2'); await login(next); await next.claim();
    check(e.posts == 1 && identical(intent, s.row), 'new generation must not replay unknown intent');
  });
  await test('missing complete balance cannot persist or send', () async {
    final e = SyntheticExchange(), s = MemoryStore();
    final f = owner(e, s, before: null); await login(f); await f.claim();
    check(f.result?.state == WorkBuddyState.unconfirmed && e.posts == 0 && s.row == null,
      'partial/missing balance must fail closed');
  });
  await test('receipt without corroborating increase is never credited', () async {
    final e = SyntheticExchange(), s = MemoryStore();
    final f = owner(e, s, after: 10); await login(f); await f.claim();
    check(f.result?.state == WorkBuddyState.unconfirmed && f.result?.credited == null,
      'receipt is not credit proof');
  });
  await test('failed durable commit blocks claim POST', () async {
    final e = SyntheticExchange(), s = MemoryStore()..deny = true;
    final f = owner(e, s); await login(f); await f.claim();
    check(e.posts == 0 && f.result?.state == WorkBuddyState.unconfirmed, 'durability required');
  });
  await test('status refresh is read-only and never manufactures claim result', () async {
    final e = SyntheticExchange(); final f = owner(e, MemoryStore());
    await login(f); await f.refreshStatus();
    check(f.status == WorkBuddyState.available && f.result == null && e.posts == 0,
      'eligibility observation is not a claim');
  });
  await test('owner revocation before action performs no traffic', () async {
    var current = true; final e = SyntheticExchange();
    final f = owner(e, MemoryStore(), current: () => current); await login(f);
    current = false; final count = e.requests;
    await f.refreshStatus(); await f.claim();
    check(e.requests == count && !f.canClaim, 'retired owner cannot send');
  });
  await test('revocation after dispatch leaves unknown intent', () async {
    var current = true; final e = SyntheticExchange()..afterClaim = () { current = false; };
    final s = MemoryStore();
    final active = owner(e, s, current: () => current); await login(active); await active.claim();
    check(s.row?.receipt == WorkBuddyState.unconfirmed && e.posts == 1 &&
      active.result?.state != WorkBuddyState.claimed, 'revocation cannot erase sent intent');
  });
  await test('closed page drops late claim display but retains persisted intent', () async {
    final e = SyntheticExchange()..waitClaim = Completer<void>(), s = MemoryStore();
    final f = owner(e, s); await login(f); final claim = f.claim();
    while (e.posts == 0) { await Future<void>.delayed(Duration.zero); }
    check(f.isCurrent(s.row!.subject), 'balance owner can check the bound identity');
    check(!f.isCurrent(WorkBuddySubject('www.workbuddy.cn', 'synthetic-user', 'other')),
      'balance reader cannot accept a different generation');
    f.close(); e.waitClaim!.complete(); await claim;
    check(f.uid == null && !f.canClaim && f.result == null && s.row != null,
      'page close retires only memory, not intent');
    check(!f.isCurrent(s.row!.subject), 'closing retires the balance-reader gate');
  });
  await test('desktop activation reuses the verified account without a claim', () async {
    final exchange = SyntheticExchange();
    final flow = owner(exchange, MemoryStore());
    await login(flow);
    final requests = exchange.requests;
    var activations = 0;
    final outcome = await flow.activateDesktop((session) async {
      activations++;
      final document = session.nativeMessage();
      check((document['account'] as Map)['uid'] == 'synthetic-user', 'verified profile');
      check((document['auth'] as Map)['accessToken'] == 'synthetic-secret', 'saved grant');
      return 'opened';
    });
    check(outcome == 'opened' && activations == 1, 'one activation result');
    check(exchange.requests == requests + 1 && exchange.posts == 0, 'profile read only');
    check(!flow.busy, 'owner released after activation');
    flow.close();
  });
  await test('desktop activation excludes concurrent claim and activation', () async {
    final exchange = SyntheticExchange();
    final flow = owner(exchange, MemoryStore());
    await login(flow);
    final entered = Completer<void>(), finish = Completer<String>();
    final first = flow.activateDesktop((_) {
      entered.complete();
      return finish.future;
    });
    await entered.future;
    final requests = exchange.requests;
    await flow.claim();
    final second = await flow.activateDesktop((_) async => throw StateError('duplicate activation'));
    check(second == 'unavailable' && exchange.requests == requests, 'concurrent actions withheld');
    finish.complete('cancelled');
    check(await first == 'cancelled' && !flow.busy, 'cancellation releases owner');
    flow.close();
  });
  await test('retiring the account during profile verification withholds activation', () async {
    final exchange = SyntheticExchange();
    final flow = owner(exchange, MemoryStore());
    await login(flow);
    exchange.waitProfile = Completer<void>();
    var invoked = false;
    final operation = flow.activateDesktop((_) async {
      invoked = true;
      return 'opened';
    });
    flow.close();
    exchange.waitProfile!.complete();
    try {
      await operation;
    } on WorkBuddyApiFailure {
      // The API reports owner expiry before a native command is dispatched.
    }
    check(!invoked, 'retired owner cannot dispatch a native write');
  });
  await test('retiring after native dispatch preserves an unknown outcome', () async {
    final exchange = SyntheticExchange();
    final flow = owner(exchange, MemoryStore());
    await login(flow);
    final entered = Completer<void>(), finish = Completer<String>();
    final operation = flow.activateDesktop((_) {
      entered.complete();
      return finish.future;
    });
    await entered.future;
    flow.close();
    finish.complete('opened');
    check(await operation == 'unknown' && flow.uid == null, 'late result cannot restore retired identity');
  });
  print('$passed passed; $failed failed');
  if (failed > 0) throw StateError('WorkBuddy owner checks failed');
}
