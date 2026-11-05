// Test-only actual Rust-core driver. Never imported by lib/ or a native Runner.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../lib/zcode_native.dart';
import '../lib/zcode_promotions.dart';

int checks = 0;
void check(bool value, String why) {
  if (!value) throw StateError(why);
  checks++;
}
class RustFixture {
  final Process process;
  final StreamIterator<String> replies;
  final List<Object?> seen = [];
  final Future<String> stderrText;
  RustFixture._(this.process, this.replies, this.stderrText);
  static Future<RustFixture> start() async {
    final path = Platform.script.resolve('../native/synthetic-harness/target/debug/loongpass-zcode-synthetic-harness').toFilePath();
    final process = await Process.start(path, []);
    return RustFixture._(process, StreamIterator(process.stdout.transform(utf8.decoder).transform(const LineSplitter())), process.stderr.transform(utf8.decoder).join());
  }
  Future<Object?> call(String method, Map<String,Object?> arguments) async {
    process.stdin.writeln(jsonEncode({'method': method, ...arguments}));
    await process.stdin.flush();
    if (!await replies.moveNext()) throw StateError('synthetic Rust process ended');
    final result = jsonDecode(replies.current);
    seen.add(result);
    if (result is Map && result.containsKey('error')) {
      throw ZcodeNativeFailure.fromCode(result['error']);
    }
    return result;
  }
  Future<void> close() async {
    await process.stdin.close();
    check(await process.exitCode == 0, 'synthetic process exit');
    check((await stderrText).isEmpty, 'no native diagnostic leakage');
    final output = jsonEncode(seen);
    check(!output.contains('SYNTHETIC-INTEGRATED-SECRET') && !output.contains('SYNTHETIC-INTEGRATED-TOKEN') && !output.contains('enc:v1:'), 'no synthetic secret crosses client boundary');
    await replies.cancel();
  }
}
Future<void> main() async {
  final fixture = await RustFixture.start();
  try {
    final native = ZcodeNativeClient(call:fixture.call);
    final promotion = ZcodePromotionsClient(call:fixture.call);
    check((await native.status()).reason == 'WritersActive', 'writer initially active');
    check((await native.requestStop()).reason == 'NativeCaptureRequired', 'stop does not imply capture');
    final source = await native.captureCurrent();
    final target = await native.captureSelected();
    check(source.accountId != target.accountId, 'actual native authentication produced distinct account handles');
    final switched = await native.switchAccount(accountId:target.accountId, expectedRevision:source.revision);
    check(switched.outcome == 'switched' && switched.operationId != null, 'actual switch core committed synthetic file');
    check((await native.captureCurrent()).accountId == target.accountId, 'actual switched ciphertext readback');
    check((await native.restore(operationId:switched.operationId!)).outcome == 'restored', 'conditional restore through original ABI');
    check((await native.captureCurrent()).accountId == source.accountId, 'original account restored');
    check((await promotion.status()).available, 'test-only promotion owner available');
    check((await promotion.preview(source.accountId)).status == 'claimable', 'actual promotion Worker preview');
    check((await promotion.claim(source.accountId, automatic:false)).status == 'claimed', 'actual Worker confirmed receipt');
    check((await promotion.preview(source.accountId)).status == 'noClaim', 'known receipt blocks stale balance repost');
    await fixture.call('testScenario', {'accountId':target.accountId,'scenario':'timeout'});
    check((await promotion.preview(target.accountId)).status == 'claimable', 'second account has independent scope');
    check((await promotion.claim(target.accountId, automatic:false)).status == 'resultPending', 'unknown request stays pending');
    check((await promotion.claim(target.accountId, automatic:true)).status == 'resultPending', 'second native round does balance only despite claim command');
    await fixture.call('testScenario', {'accountId':target.accountId,'scenario':'timeout','active':true});
    check((await promotion.preview(target.accountId)).status == 'claimed', 'new same-plan active instance confirms pending');
    final counters = await fixture.call('testCounters', {}) as Map;
    final accounts = counters['accounts'] as Map;
    check((accounts[source.accountId] as Map)['posts'] == 1, 'one source account POST');
    check((accounts[target.accountId] as Map)['posts'] == 1, 'no second POST after timeout');
    check(counters['sourceRestored'] == true, 'exact original file bytes restored');
    check(((accounts[target.accountId] as Map)['calls'] as List).join(',') == 'Balance,Preview,Balance,Preview,Claim,Balance,Balance', 'uncertain follow-ups contain balance only');
  } finally {
    await fixture.close();
  }
  print('$checks dual-core integration checks passed; pure Dart -> test-only Rust process -> unchanged switch ABI and promotion Worker; not Flutter/Swift acceptance.');
}
