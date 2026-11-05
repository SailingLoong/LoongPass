import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../lib/workbuddy_api.dart';
import '../lib/workbuddy_account_flow.dart';
import '../lib/workbuddy_claim.dart';
import '../lib/workbuddy_attempt_journal.dart';
import 'workbuddy_flow_checks.dart' as synthetic;

void check(bool value, String why) { if (!value) throw StateError(why); }

class BalanceExchange implements WorkBuddyExchange {
  final requests = <WorkBuddyRequest>[];
  Completer<void>? waitSummary;
  bool truncated = false;
  double summaryRemaining = 7;
  void Function()? afterSummary;
  @override Future<Map<String,Object?>> send(WorkBuddyRequest r, bool Function() admitted) async {
    check(admitted(), 'actual send boundary is gated');
    requests.add(r);
    if (r.uri.path.endsWith('summary')) {
      afterSummary?.call();
      await waitSummary?.future;
      return {'code': 0, 'data': {'Packages': [{'PackageCode': 'summary-only',
        'CapacityRemain': summaryRemaining}], 'TotalCount': 1}};
    }
    if (r.uri.path.endsWith('paid-packages')) {
      return {'code': 0, 'data': {'Accounts': [{'ResourceId': 'paid-one',
        'PackageCode': 'paid-package', 'CapacityRemain': 3}], 'TotalCount': truncated ? 201 : 1}};
    }
    if (r.uri.path.endsWith('free-packages')) {
      return {'code': 0, 'data': {'Accounts': [], 'TotalCount': 0}};
    }
    throw StateError('unexpected endpoint');
  }
}

class OwnerExchange implements WorkBuddyExchange {
  final auth = synthetic.SyntheticExchange();
  final balance = BalanceExchange();
  OwnerExchange() { auth.afterClaim=(){balance.summaryRemaining=27;}; }
  @override Future<Map<String,Object?>> send(WorkBuddyRequest r, bool Function() admitted) =>
    r.uri.path.startsWith('/billing/') ? balance.send(r, admitted) : auth.send(r, admitted);
}

Future<void> main() async {
  var passed = 0, failed = 0;
  Future<void> test(String name, Future<void> Function() body) async {
    try { await body(); passed++; print('PASS $name'); }
    catch (error) { failed++; print('FAIL $name: $error'); }
  }
  final account = WorkBuddyAccount('www.workbuddy.cn','synthetic-user','synthetic-secret');
  final subject = WorkBuddySubject(account.domain, account.uid, 'generation');
  WorkBuddyApi api(BalanceExchange e, {DateTime Function()? now}) =>
    WorkBuddyApi(e, isCurrent: () => true, now: now ?? () => DateTime.utc(2026,11,4,4));

  await test('complete balance uses three authenticated existing endpoints', () async {
    final e = BalanceExchange(); final result = await api(e).completeBalance(account, subject, gate: () => true);
    check(result.subject.matches(subject) && result.totalRemaining == 10, 'complete total should be 10');
    check(e.requests.length == 3, 'exactly summary, paid, free');
    for (final r in e.requests) {
      check(r.method == 'POST' && r.uri.host == 'www.workbuddy.cn', 'bound account endpoint');
      check(r.headers['Authorization'] == 'Bearer synthetic-secret' && r.headers['X-User-Id'] == 'synthetic-user', 'account identity headers');
      check(!r.headers.keys.any((k) => ['origin','referer','x-client-platform'].contains(k.toLowerCase())), 'no official-client impersonation');
    }
  });
  await test('incomplete package page never becomes partial balance', () async {
    final e = BalanceExchange()..truncated = true;
    final result = await api(e).completeBalance(account, subject, gate: () => true);
    check(result.totalRemaining == null, 'missing rows are not a complete total');
  });
  await test('pinned package request bodies retain bounded paging and China-day slices', () async {
    final e=BalanceExchange();
    await api(e,now:()=>DateTime.utc(2026,11,4,16)).completeBalance(account,subject,gate:()=>true);
    final summary=jsonDecode(e.requests[0].body) as Map;
    final paid=jsonDecode(e.requests[1].body) as Map;
    final free=jsonDecode(e.requests[2].body) as Map;
    check(summary.isEmpty,'summary body remains empty');
    check(paid['PageNumber']==1&&paid['PageSize']==200&&paid['NeedRenewInfo']==true&&paid['IsDisplayTotalInfo']==true,'paid body matches pinned contract');
    check(jsonEncode(paid['Status'])=='[0,3]'&&(paid['PackageCodes'] as List).length==8,'paid codes and statuses');
    check((paid['PackageCodes'] as List).first=='TCACA_code_002_AkiJS3ZHF5'&&(paid['PackageCodes'] as List).last=='TCACA_code_036_lupO5WgNdG','paid pinned boundary codes');
    check(free['PageNumber']==1&&free['PageSize']==200&&(free['PackageCodes'] as List).length==11&&free['IsDisplayTotalInfo']==true,'free body matches pinned contract');
    check(free['SlicePeriodStartTime']=='2026-11-05 00:00:00'&&free['SlicePeriodEndTime']=='2026-11-05 23:59:59','slices use UTC+8 instead of local day');
  });
  await test('foreign subject is refused before balance request', () async {
    final e = BalanceExchange(); var refused = false;
    try { await api(e).completeBalance(account, WorkBuddySubject(account.domain,'foreign','generation'), gate: () => true); }
    catch (_) { refused = true; }
    check(refused && e.requests.isEmpty, 'cannot rebind credentials');
  });
  await test('cancel during summary prevents paid and free requests', () async {
    final e = BalanceExchange()..waitSummary = Completer<void>(); final service = api(e);
    final pending = service.completeBalance(account, subject, gate: () => true);
    service.cancel(); e.waitSummary!.complete();
    var refused = false;
    try { await pending; } catch (_) { refused = true; }
    check(refused && e.requests.length == 1, 'cancelled batch must stop');
  });
  await test('owner revoked after summary prevents later dispatch', () async {
    var current = true; final e = BalanceExchange()..afterSummary = () { current = false; };
    var refused = false;
    try { await api(e).completeBalance(account, subject, gate: () => current); } catch (_) { refused = true; }
    check(refused && e.requests.length == 1, 'owner gate must apply across awaits');
  });
  await test('China midnight during balance batch never returns complete total', () async {
    var now = DateTime.utc(2026,11,4,15,59,59);
    final e = BalanceExchange()..afterSummary = () { now = DateTime.utc(2026,11,4,16); };
    final result = await api(e, now: () => now).completeBalance(account, subject, gate: () => true);
    check(result.totalRemaining == null, 'day boundary makes observation inconclusive');
  });
  await test('memory factory is lazy, supplies real reader and cannot claim without storage', () async {
    final e = OwnerExchange(); final f = WorkBuddyAccountFlow.inMemory(exchange: e,
      now: () => DateTime.utc(2026,11,4,4));
    check(e.auth.requests == 0 && e.balance.requests.isEmpty, 'construction sends nothing');
    await f.begin(); await f.poll(); await f.refreshBalance();
    check(f.uid == 'synthetic-user' && f.totalRemaining == 10, 'reader uses same verified private account');
    check(!f.canClaim, 'no durable store means no claim');
    await f.claim(); check(e.auth.posts == 0, 'cannot bypass durable store');
    f.close(); final count = e.balance.requests.length;
    await f.refreshBalance(); check(f.uid == null && f.totalRemaining == null && e.balance.requests.length == count, 'close retires memory owner');
  });
  await test('default balance reader and existing injected store reach only reviewed claim core', () async {
    final e=OwnerExchange(),store=synthetic.MemoryStore();
    final f=WorkBuddyAccountFlow(exchange:e,ownerGeneration:'synthetic-owner',isOwnerCurrent:()=>true,
      store:store,now:()=>DateTime.utc(2026,11,4,4));
    await f.begin();await f.poll();await f.claim();
    check(f.result?.state==WorkBuddyState.claimed&&f.result?.credited==20,'default reader corroborates receipt');
    check(e.auth.posts==1&&store.row?.settled==WorkBuddyState.claimed,'intent and settlement persist through existing store');
    await f.claim();check(e.auth.posts==1,'no second POST');
  });
  for(final unknown in [false,true]) {
    await test('full API owner reopens noncredential journal without replay (unknown=$unknown)',() async {
      var root=await Directory.systemTemp.createTemp('workbuddy-wiring-');
      root=Directory(await root.resolveSymbolicLinks());
      try {
        final chmod=await Process.run('chmod',['700',root.path]);
        check(chmod.exitCode==0,'private synthetic fixture root');
        final exchange=OwnerExchange()..auth.loseReceipt=unknown;
        late WorkBuddyAccountFlow flow;
        final journal=WorkBuddyAttemptJournal(root,syncDirectory:() async {},isCurrent:(s)=>flow.isCurrent(s));
        flow=WorkBuddyAccountFlow.inMemory(exchange:exchange,store:journal,now:()=>DateTime.utc(2026,11,4,4));
        await flow.begin();await flow.poll();await flow.claim();
        check(exchange.auth.posts==1,'exactly one initial POST');
        check(flow.result?.state==(unknown?WorkBuddyState.unconfirmed:WorkBuddyState.claimed),'receipt outcome not fabricated');
        final file=File('${root.path}/workbuddy-intents.jsonl');
        final original=await file.readAsString();
        check(!original.contains('synthetic-secret')&&!original.contains('accessToken')&&!original.contains('Authorization'),'no credential in persisted state');
        flow.close();
        late WorkBuddyAccountFlow reopened;
        final persisted=WorkBuddyAttemptJournal(root,syncDirectory:() async {},isCurrent:(s)=>reopened.isCurrent(s));
        reopened=WorkBuddyAccountFlow.inMemory(exchange:exchange,store:persisted,now:()=>DateTime.utc(2026,11,4,4));
        await reopened.begin();await reopened.poll();await reopened.claim();
        check(exchange.auth.posts==1,'recreated production owner must not repeat POST');
        check(reopened.result?.state==(unknown?WorkBuddyState.unconfirmed:WorkBuddyState.alreadyClaimed),'reopened journal outcome');
        check(await file.readAsString()==original,'reopening preserves existing receipt/unknown intent');
        reopened.close();
      } finally { await root.delete(recursive:true); }
    });
  }
  print('$passed passed; $failed failed');
  if (failed > 0) throw StateError('wiring checks failed');
}
