import 'dart:convert';
import 'dart:async';

import '../lib/zcode_api.dart';
import 'memory_account_store.dart';
import 'zcode_activities_checks.dart' as fixture;

Future<void> main() async {
  final store = MemoryAccountStore('device-binding');
  final http = fixture.FakeZcode();
  final owner = await fixture.account(store, http);
  final before = http.received.length;
  var occupied = false;
  try {
    await owner.beginAuthorization('bigmodel', fixture.context);
  } on ZcodeFailure catch (e) {
    occupied = e.code == 'device_in_use';
  }
  fixture.check(
    occupied,
    'new account must not authorize using an occupied native device',
  );
  fixture.check(
    http.received.length == before,
    'occupied device must be rejected before OAuth',
  );
  final id = (await owner.accounts()).single.id;
  const first = '22222222-2222-4333-8444-555555555555';
  const second = '33333333-2222-4333-8444-555555555555';
  store.data['devicePool'] = [fixture.context['deviceMid'], first, second];
  http.loseReply = true;
  http.revealReceipt = false;
  await owner.claim(id);
  final previous = jsonEncode(store.data['accounts'][id]);
  await owner.beginAuthorization(
    'bigmodel',
    fixture.context,
    accountId: id,
    replaceDevice: true,
  );
  fixture.check(
    http.received.last.context['deviceMid'] == first,
    'rebind must choose the first unoccupied imported ID',
  );
  owner.cancelAuthorization();
  fixture.check(
    jsonEncode(store.data['accounts'][id]) == previous,
    'cancelled rebind must not change saved credentials, context or pending journal',
  );
  final start = http.received.length;
  await owner.beginAuthorization(
    'bigmodel',
    fixture.context,
    accountId: id,
    replaceDevice: true,
  );
  var failSave = true;
  store.beforeWrite = () async {
    if (failSave) throw StateError('synthetic failure');
  };
  try {
    await owner.pollAuthorizationOnce();
  } on ZcodeFailure catch (_) {}
  fixture.check(
    owner.loginPending && jsonEncode(store.data['accounts'][id]) == previous,
    'save failure must retain old binding and obtained authorization',
  );
  failSave = false;
  await owner.pollAuthorizationOnce();
  final rebound = store.data['accounts'][id];
  fixture.check(
    rebound['context']['deviceMid'] == first,
    'official identity must commit selected device',
  );
  fixture.check(
    rebound['bindingHistory'][0]['claims']['night']['state'] == 'pending' &&
        rebound['claims'].isEmpty,
    'old uncertain intent belongs to retained old binding',
  );
  fixture.check(
    !jsonEncode(rebound['bindingHistory']).contains('synthetic-bigmodel'),
    'binding history must not copy old credentials',
  );
  fixture.check(
    http.received.skip(start).every((r) => r.context['deviceMid'] == first),
    'init and polling must use one fixed imported device',
  );
  fixture.check(
    await owner.availableDeviceCount() == 1,
    'current and retired devices cannot be reallocated',
  );
  http.loseReply = false;
  http.revealReceipt = true;
  http.balances.clear();
  await owner.claim(id);
  fixture.check(
    http.claims == 2 && http.received.last.context['deviceMid'] == first,
    'explicit new binding permits one new attempt using only selected device',
  );
  await owner.tick();
  fixture.check(
    http.claims == 2,
    'successful claim must not repeat after rebind',
  );
  final lastSaved = jsonEncode(store.data['accounts'][id]);
  await owner.beginAuthorization(
    'bigmodel',
    fixture.context,
    accountId: id,
    replaceDevice: true,
  );
  // Simulate a different writer replacing this target binding while OAuth runs.
  store.data['accounts'][id]['context']['deviceMid'] =
      '44444444-2222-4333-8444-555555555555';
  var changed = false;
  try {
    await owner.pollAuthorizationOnce();
  } on ZcodeFailure catch (e) {
    changed = e.code == 'binding_changed';
  }
  fixture.check(
    changed,
    'a stale authorization must not overwrite a newer binding',
  );
  store.data['accounts'][id] = jsonDecode(lastSaved);
  await owner.beginAuthorization(
    'bigmodel',
    fixture.context,
    accountId: id,
    replaceDevice: true,
  );
  final writing = Completer<void>(), release = Completer<void>();
  store.beforeWrite = () async {
    writing.complete();
    await release.future;
  };
  final save = owner.pollAuthorizationOnce();
  await writing.future;
  owner.cancelAuthorization();
  fixture.check(
    owner.loginPending,
    'cancellation cannot discard the login once publication begins',
  );
  release.complete();
  await save;
  fixture.check(
    !owner.loginPending &&
        store.data['accounts'][id]['context']['deviceMid'] == second,
    'in-progress publication must reconcile its committed binding',
  );
  owner.dispose();
  final legacyStore = MemoryAccountStore('shared-legacy-device');
  final legacyHttp = fixture.FakeZcode();
  final legacy = await fixture.account(legacyStore, legacyHttp);
  final originalId = (await legacy.accounts()).single.id;
  await legacy.claim(originalId);
  legacyStore.data['devicePool'] = [first, second];
  legacyHttp.userId = 'second-account';
  await legacy.beginAuthorization('bigmodel', fixture.context);
  await legacy.pollAuthorizationOnce();
  final otherId = (await legacy.accounts())
      .singleWhere((a) => a.uid == 'second-account')
      .id;
  // Reproduce the pre-fix document: two identities used the same native ID.
  legacyStore.data['accounts'][otherId]['context']['deviceMid'] =
      fixture.context['deviceMid'];
  final protectedAccount = jsonEncode(legacyStore.data['accounts'][originalId]);
  await legacy.beginAuthorization(
    'bigmodel',
    fixture.context,
    accountId: otherId,
    replaceDevice: true,
  );
  await legacy.pollAuthorizationOnce();
  fixture.check(
    jsonEncode(legacyStore.data['accounts'][originalId]) == protectedAccount,
    'rebinding another account must preserve the successful account byte-for-byte',
  );
  legacyHttp.userId = 'same-id';
  await legacy.beginAuthorization(
    'bigmodel',
    fixture.context,
    accountId: originalId,
  );
  await legacy.pollAuthorizationOnce();
  fixture.check(
    legacyStore.data['accounts'][originalId]['context']['deviceMid'] ==
        fixture.context['deviceMid'],
    'successful legacy owner must refresh on its original device despite the other account history',
  );
  legacy.dispose();
  final lostStore = MemoryAccountStore('binding-lost-write-ack');
  final lostHttp = fixture.FakeZcode();
  final lost = await fixture.account(lostStore, lostHttp);
  final lostId = (await lost.accounts()).single.id;
  lostStore.data['devicePool'] = [first, second];
  await lost.beginAuthorization(
    'bigmodel',
    fixture.context,
    accountId: lostId,
    replaceDevice: true,
  );
  lostStore.afterWrite = () async {
    throw StateError('ack lost');
  };
  try {
    await lost.pollAuthorizationOnce();
  } on ZcodeFailure catch (_) {}
  fixture.check(
    !lost.cancelAuthorization() && lost.loginPending,
    'lost commit acknowledgement must not report cancellation',
  );
  lostStore.afterWrite = null;
  final polls = lostHttp.polls;
  await lost.pollAuthorizationOnce();
  fixture.check(
    lostHttp.polls == polls &&
        lostStore.data['accounts'][lostId]['bindingHistory'].length == 1,
    'retry must reuse obtained grant and not duplicate binding history',
  );
  final committed = jsonEncode(lostStore.data['accounts']);
  lostHttp.userId = 'wrong-account';
  await lost.beginAuthorization(
    'bigmodel',
    fixture.context,
    accountId: lostId,
    replaceDevice: true,
  );
  var mismatch = false;
  try {
    await lost.pollAuthorizationOnce();
  } on ZcodeFailure catch (e) {
    mismatch = e.code == 'account_mismatch';
  }
  fixture.check(
    mismatch &&
        !lost.loginPending &&
        jsonEncode(lostStore.data['accounts']) == committed,
    'wrong official identity cannot replace the selected account',
  );
  lostHttp.userId = 'same-id';
  await lost.beginAuthorization(
    'bigmodel',
    fixture.context,
    accountId: lostId,
    replaceDevice: true,
  );
  lostStore.afterWrite = () async {
    throw StateError('ack lost again');
  };
  try {
    await lost.pollAuthorizationOnce();
  } on ZcodeFailure catch (_) {}
  lostStore.afterWrite = null;
  lostStore.data['accounts'][lostId]['context']['deviceMid'] =
      '44444444-2222-4333-8444-555555555555';
  try {
    await lost.pollAuthorizationOnce();
  } on ZcodeFailure catch (_) {}
  fixture.check(
    !lost.loginPending,
    'a conflicting binding after an unknown publication must terminate the stale flow',
  );
  lost.dispose();
  final compatibleStore = MemoryAccountStore('legacy-uuid-contract');
  final compatible = await fixture.account(
    compatibleStore,
    fixture.FakeZcode(),
    deviceContext: {
      ...fixture.context,
      'deviceMid': '11111111-2222-3333-4444-555555555555',
    },
  );
  fixture.check(
    (await compatible.accounts()).length == 1 &&
        await compatible.availableDeviceCount() == 0,
    'legacy native UUID acceptance must not hide saved accounts',
  );
  compatible.dispose();
  print('ZCode device binding checks passed');
}
