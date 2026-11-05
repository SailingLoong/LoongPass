import 'dart:async';
import '../lib/zcode_native.dart';
import '../lib/zcode_promotions.dart';
import '../lib/zcode_workspace.dart';
import 'zcode_promotions_checks.dart' as promotion;

void check(bool condition, String label) {
  if (!condition) throw StateError(label);
}

class Boundary {
  final calls = <String>[];
  final args = <Map<String, Object?>>[];
  Completer<void>? pause;
  String? pausedMethod;
  String account = 'a' * 64;
  String revision = 'b' * 64;
  Object? claimReply = promotion.view(status: 'claimed', canClaim: false);
  bool uncertain = false;
  bool previewFails = false;
  bool captureRequired = false;
  bool promotionUncertain = false;
  bool captureFails = false;
  Future<Object?> call(String method, Map<String, Object?> arguments) async {
    calls.add(method); args.add(arguments);
    if (method == pausedMethod) await pause!.future;
    switch (method) {
      case 'status':
        return {'available': !captureRequired,
          'reason': captureRequired ? 'NativeCaptureRequired' : null};
      case 'promotionStatus':
        return {'available': !promotionUncertain,
          'reason': promotionUncertain ? 'CommitUncertain' : null};
      case 'requestStop': case 'reopen':
        return {'available': true, 'reason': null};
      case 'captureCurrent':
        if (captureFails) throw ZcodeNativeFailure.fromCode('SourceChanged');
        captureRequired = false;
        return {'accountId': account, 'revision': revision, 'family': 'zai',
          'label': 'Synthetic account'};
      case 'captureSelected':
        return {'accountId': account, 'revision': revision, 'family': 'zai',
          'label': 'Synthetic account'};
      case 'switchAccount':
        if (uncertain) throw ZcodeNativeFailure.fromCode('CommitUncertain');
        return {'outcome': 'switched', 'operationId': 'c' * 64};
      case 'restore': case 'restoreSelected':
        return {'outcome': 'restored', 'operationId': 'c' * 64};
      case 'previewPromotions':
        if (previewFails) throw ZcodeNativeFailure.fromCode('NativeUnavailable');
        return promotion.view();
      case 'claimPromotions': return claimReply;
    }
    throw StateError('unexpected method');
  }
  ZcodeWorkspace workspace({bool enabled = true, void Function()? onChanged}) =>
    ZcodeWorkspace(native: ZcodeNativeClient(call: call),
      promotions: ZcodePromotionsClient(call: call), nativeValidated: enabled,
      onChanged: onChanged);
}

Future<void> prepare(ZcodeWorkspace owner) async {
  await owner.refreshStatus();
  await owner.captureCurrent();
}

Future<void> main() async {
  final closed = Boundary();
  final disabled = closed.workspace(enabled: false);
  await disabled.refreshStatus(); await disabled.requestStop();
  await disabled.captureCurrent(); await disabled.captureSelected();
  await disabled.previewPromotions(); await disabled.claimPromotions();
  disabled.setAutomatic(true); await disabled.automaticTick();
  await disabled.restoreSelected(); await disabled.reopen();
  check(closed.calls.isEmpty && !disabled.automatic,
      'false gate blocks all native calls, including automatic');
  disabled.dispose();

  final synchronouslyClosed = Boundary();
  late ZcodeWorkspace closing;
  closing = synchronouslyClosed.workspace(onChanged: () {
    if (closing.busy) closing.dispose();
  });
  await closing.refreshStatus();
  check(synchronouslyClosed.calls.isEmpty,
      'disposal from a UI callback prevents dispatch, not just result publication');

  final first = Boundary()..captureRequired = true;
  final fresh = first.workspace(); await fresh.refreshStatus();
  check(fresh.canCapture && !fresh.canSwitch && !fresh.nativeStatus.available,
      'first native capture remains accessible without pretending native is ready');
  await fresh.captureSelected();
  check(!fresh.canSwitch, 'selected capture alone does not authenticate current source');
  await fresh.captureCurrent();
  check(fresh.nativeStatus.available && fresh.canSwitch && first.calls.last == 'status',
      'current capture explicitly rechecks native readiness');
  fresh.dispose();

  final latched = Boundary(); final readOnly = latched.workspace();
  await prepare(readOnly); await readOnly.previewPromotions();
  latched.promotionUncertain = true;
  await readOnly.refreshStatus();
  check(readOnly.canPreview && !readOnly.canClaim && !readOnly.canEnableAutomatic,
      'uncertain backend retains read-only verification after status refresh');
  await readOnly.previewPromotions();
  check(latched.calls.last == 'previewPromotions' && !readOnly.canClaim,
      'a claimable view cannot bypass unavailable native mutation gate');
  final callsBeforeRefusedClaim = latched.calls.length;
  readOnly.setAutomatic(true); await readOnly.automaticTick();
  await readOnly.claimPromotions();
  check(!readOnly.automatic && latched.calls.length == callsBeforeRefusedClaim,
      'uncertain backend cannot restart manual or automatic claim dispatch');
  readOnly.dispose();

  final recapture = Boundary(); final recaptured = recapture.workspace();
  await prepare(recaptured);
  check(recaptured.canSwitch, 'initial capture is valid before recapture regression');
  recapture.captureFails = true;
  await recaptured.captureCurrent();
  check(recaptured.current == null && !recaptured.nativeStatus.available &&
      !recaptured.canSwitch && recaptured.failureCode == 'SourceChanged',
      'failed recapture revokes old current snapshot and source readiness');
  final callsAfterFailure = recapture.calls.length;
  await recaptured.switchSelected();
  check(recapture.calls.length == callsAfterFailure,
      'failed recapture cannot reuse an old revision for switching');
  recaptured.dispose();

  final wire = Boundary(); final owner = wire.workspace();
  check(wire.calls.isEmpty, 'constructor is inert');
  owner.setAutomatic(true); await owner.automaticTick();
  check(wire.calls.isEmpty && !owner.automatic, 'no selection means no automatic');
  await prepare(owner);
  check(owner.selected?.accountId == wire.account && owner.current?.revision == wire.revision,
      'capture is in-memory and retains current revision');
  wire.account = 'd' * 64;
  await owner.captureSelected();
  await owner.switchSelected();
  final at = wire.calls.indexOf('switchAccount');
  check(wire.args[at]['accountId'] == 'd' * 64 &&
      wire.args[at]['expectedRevision'] == 'b' * 64,
      'switch binds selected account to captured current revision');
  check(owner.current == null && owner.canRestoreLast, 'switch requires recapture and offers conditional restore');
  await owner.restoreLast();
  check(!owner.canRestoreLast && wire.calls.last == 'restore', 'restore dispatched once');
  await owner.previewPromotions();
  check(owner.canClaim, 'server preview admits manual claim');
  wire.previewFails = true; await owner.previewPromotions();
  check(!owner.canClaim, 'failed refresh cannot reuse a previously claimable preview');
  wire.previewFails = false; await owner.previewPromotions();
  await owner.claimPromotions();
  check(owner.promotion.status == 'claimed' && !owner.canClaim, 'claim is observed, not fabricated');
  owner.dispose();

  final overlap = Boundary(); final serial = overlap.workspace();
  await prepare(serial); serial.setAutomatic(true);
  overlap.pausedMethod = 'previewPromotions'; overlap.pause = Completer<void>();
  final tick = serial.automaticTick();
  await Future<void>.delayed(Duration.zero);
  check(serial.busy, 'automatic and switch share busy admission');
  await serial.automaticTick(); await serial.switchSelected();
  await serial.claimPromotions();
  check(overlap.calls.where((x) => x == 'previewPromotions').length == 1 &&
      !overlap.calls.contains('switchAccount') && !overlap.calls.contains('claimPromotions'),
      'no overlapping tick, switch, or claim');
  serial.setAutomatic(false);
  overlap.pause!.complete(); await tick;
  check(!overlap.calls.contains('claimPromotions'), 'opt-out during preview prevents POST');
  overlap.pausedMethod = null;
  serial.setAutomatic(true); await serial.automaticTick();
  check(overlap.calls.last == 'claimPromotions' && overlap.args.last['automatic'] == true,
      'opted-in tick previews before exactly one native claim');
  serial.dispose();

  final changed = Boundary(); final context = changed.workspace();
  await prepare(context);
  changed.account = 'e' * 64; await context.captureSelected();
  context.setAutomatic(true);
  changed.pausedMethod = 'previewPromotions'; changed.pause = Completer<void>();
  final stale = context.automaticTick(); await Future<void>.delayed(Duration.zero);
  context.selectAccount('a' * 64);
  changed.pause!.complete(); await stale;
  check(!context.automatic && context.promotion.status == 'unknown' &&
      !changed.calls.contains('claimPromotions'), 'selection revokes consent and discards old preview');
  context.dispose();

  final failed = Boundary()..claimReply = {'status': 'new-unknown-state'};
  final unresolved = failed.workspace(); await prepare(unresolved);
  unresolved.setAutomatic(true); await unresolved.automaticTick();
  final afterUnknown = failed.calls.length;
  await unresolved.automaticTick(); await unresolved.claimPromotions();
  check(!unresolved.automatic && !unresolved.canClaim &&
      unresolved.promotion.status == 'unknown' && failed.calls.length == afterUnknown,
      'unknown claim stops automatic and requires explicit recheck');
  failed.uncertain = true; await unresolved.switchSelected();
  final afterWrite = failed.calls.length;
  await unresolved.switchSelected(); await unresolved.restoreLast();
  check(unresolved.switchOutcomeUnknown && failed.calls.length == afterWrite,
      'uncertain switch is not automatically retried or restored');
  unresolved.dispose();

  var updates = 0; final retiring = Boundary();
  final disposed = retiring.workspace(onChanged: () => updates++);
  await prepare(disposed); disposed.setAutomatic(true);
  retiring.pausedMethod = 'previewPromotions'; retiring.pause = Completer<void>();
  final pending = disposed.automaticTick(); await Future<void>.delayed(Duration.zero);
  disposed.dispose(); final callbacks = updates;
  retiring.pause!.complete(); await pending; await disposed.automaticTick();
  check(updates == callbacks && !disposed.automatic &&
      !retiring.calls.contains('claimPromotions'), 'dispose cancels timer and stale UI callbacks');
  print('PASS ZCode workspace synthetic safety, switching, and automatic controls');
}
