// Direct Dart regression for the native context-first / writer-active contract.
import '../lib/zcode_native.dart';
import '../lib/zcode_promotions.dart';
import '../lib/zcode_workspace.dart';
import 'zcode_promotions_checks.dart' as fixture;

void check(bool ok,String message){if(!ok)throw StateError(message);}
Future<void> main() async {
  String? nativeReason;
  var posts=0;
  Future<Object?> call(String method,Map<String,Object?> args) async {
    switch(method){
      case 'status': return {'available':nativeReason==null,'reason':nativeReason};
      case 'promotionStatus': return {'available':true,'reason':null};
      case 'captureCurrent': return {'accountId':'a'*64,'revision':'b'*64,'family':'zai','label':'Synthetic'};
      case 'previewPromotions': return fixture.view();
      case 'claimPromotions': posts++;return fixture.view(status:'claimed',canClaim:false);
      default: throw StateError('unexpected native call');
    }
  }
  final owner=ZcodeWorkspace(native:ZcodeNativeClient(call:call),promotions:ZcodePromotionsClient(call:call),nativeValidated:true);
  try {
    await owner.refreshStatus();await owner.captureCurrent();owner.setAutomatic(true);
    nativeReason='WritersActive';await owner.refreshStatus();
    check(owner.automatic,'verified running writers must not disable network-only promotions');
    check(!owner.canSwitch && owner.canEnableAutomatic,'running app blocks writes but not independently ready promotions');
    await owner.automaticTick();check(posts==1,'active-writer promotion uses normal one-attempt path');
    nativeReason='NativeContextUnavailable';await owner.refreshStatus();
    check(!owner.automatic,'missing context still stops automatic work');
    nativeReason='NativeCaptureRequired';await owner.refreshStatus();owner.setAutomatic(true);
    await owner.refreshStatus();check(owner.automatic,'authenticated saved promotion account need not imply current-file capture');
    nativeReason='SourceChanged';await owner.refreshStatus();check(!owner.automatic,'changed context stops automatic work');
    for(final code in ['InvalidResponse','LoginExpired','NativeUnavailable']){
      check(ZcodeNativeFailure.fromCode(code).code==code,'native owner error keeps its fixed safe meaning');
    }
  } finally {owner.dispose();}
  print('PASS native owner context-first/writer-active promotion admission and error mapping (direct Dart)');
}
