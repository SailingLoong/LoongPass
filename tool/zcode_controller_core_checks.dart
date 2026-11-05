// Integration-only: UI coordinator -> actual frozen Rust cores, synthetic files.
import '../lib/zcode_native.dart';
import '../lib/zcode_promotions.dart';
import '../lib/zcode_workspace.dart';
import 'zcode_dual_core_checks.dart' as dual;

int checks=0;
void check(bool value,String why){if(!value)throw StateError(why);checks++;}
Future<void> main() async {
  final fixture=await dual.RustFixture.start();
  final workspace=ZcodeWorkspace(native:ZcodeNativeClient(call:fixture.call),promotions:ZcodePromotionsClient(call:fixture.call),nativeValidated:true);
  try {
    check(fixture.seen.isEmpty,'construction makes no native call');
    await workspace.refreshStatus();
    check(workspace.nativeStatus.reason=='WritersActive','real ABI writer gate');
    check(!workspace.canCapture,'active writer disallows capture');
    await workspace.requestStop();
    check(workspace.nativeStatus.reason=='NativeCaptureRequired','stopped but not authenticated');
    check(workspace.canCapture,'explicit capture must break initial unavailable/capture-required cycle');
    await workspace.captureCurrent();
    final source=workspace.current!;
    check(workspace.accounts.length==1,'current native snapshot admitted');
    await workspace.captureSelected();
    final target=workspace.selected!;
    check(workspace.accounts.length==2 && source.accountId!=target.accountId,'opaque selected target imported');
    check(workspace.canSwitch,'authenticated source revision admits explicit switch');
    await workspace.switchSelected();
    check(workspace.lastOutcome=='switched','coordinator executed real switch core');
    check(workspace.current==null && !workspace.canSwitch,'switch requires a fresh source capture');
    await workspace.restoreLast();
    check(workspace.lastOutcome=='restored','coordinator executed conditional restore');
    await workspace.captureCurrent();
    check(workspace.current!.accountId==source.accountId,'restored source account authenticated');
    workspace.selectAccount(source.accountId);
    await workspace.refreshStatus();
    await workspace.previewPromotions();
    check(workspace.canClaim,'preview projection enables explicit claim');
    workspace.setAutomatic(true);
    check(workspace.automatic,'session-only opt-in set');
    await workspace.automaticTick();
    check(workspace.promotion.status=='claimed','automatic tick reaches actual promotion core');
    await workspace.automaticTick();
    check(workspace.promotion.status=='noClaim','stale server balance cannot cause second POST');
    workspace.selectAccount(target.accountId);
    check(!workspace.automatic,'selection clears previous automatic consent');
    await fixture.call('testScenario',{'accountId':target.accountId,'scenario':'timeout'});
    await workspace.previewPromotions();
    workspace.setAutomatic(true);
    await workspace.automaticTick();
    check(workspace.promotion.status=='resultPending','lost reply remains unknown');
    check(!workspace.automatic,'uncertain result pauses session auto dispatch');
    final seen=fixture.seen.length;
    await workspace.automaticTick();
    check(fixture.seen.length==seen,'paused scheduler makes no follow-up call');
    await workspace.previewPromotions();
    check(workspace.promotion.status=='resultPending' && !workspace.canClaim,'explicit read uses balance-only pending path');
    await fixture.call('testScenario',{'accountId':target.accountId,'scenario':'timeout','active':true});
    await workspace.previewPromotions();
    check(workspace.promotion.status=='claimed','new instance resolves unknown without POST');
    final counters=await fixture.call('testCounters',{}) as Map;
    final accounts=counters['accounts'] as Map;
    check((accounts[source.accountId] as Map)['posts']==1 && (accounts[target.accountId] as Map)['posts']==1,'one synthetic POST per account');
    check(counters['sourceRestored']==true,'source bytes restored exactly');
    workspace.dispose();
    final done=fixture.seen.length;
    await workspace.refreshStatus();await workspace.automaticTick();await workspace.claimPromotions();
    check(fixture.seen.length==done,'disposed coordinator cannot call native');
  } finally {workspace.dispose();await fixture.close();}
  print('$checks controller-to-core checks passed; actual Rust cores with synthetic files; Timer callback exercised via automaticTick, not a timed Flutter run.');
}
