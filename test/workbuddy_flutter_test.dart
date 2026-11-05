import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loongpass/workbuddy_flutter.dart';
import 'package:loongpass/workbuddy_api.dart';

// Written, not run in this task. Never retry denied Flutter/metadata operations.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel=MethodChannel('com.sailingloong.loongpass/files');
  tearDown(()=>TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,null));
  test('closed production factory rejects before native directory preparation',() async {
    final calls=<MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,(call) async {
      calls.add(call);return '/synthetic/LoongPass/WorkBuddy';
    });
    await expectLater(createWorkBuddyMemoryOwner(),throwsA(isA<WorkBuddyApiFailure>()
      .having((e)=>e.code,'code','WorkBuddyUnavailable')
      .having((e)=>e.mayHaveBeenSent,'mayHaveBeenSent',false)));
    expect(calls,isEmpty);
  });
  test('closed production opener rejects before native browser invocation',() async {
    final calls=<MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,(call) async {calls.add(call);return null;});
    await expectLater(openWorkBuddyAuthorization(Uri.parse('https://www.codebuddy.cn/authorize?state=synthetic')),
      throwsA(isA<WorkBuddyApiFailure>().having((e)=>e.code,'code','WorkBuddyUnavailable')));
    expect(calls,isEmpty);
  });
  test('invalid authorization never reaches native browser',() async {
    var calls=0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,(call) async {calls++;return null;});
    for(final raw in [
      'https://evil.test/authorize?state=synthetic',
      'http://www.codebuddy.cn/authorize?state=synthetic',
      'https://www.codebuddy.cn/authorize?state=a&state=b',
      'https://www.codebuddy.cn/authorize?state=a&token=secret',
      'https://www.codebuddy.cn/authorize?state=',
      'https://www.codebuddy.cn/authorize?state=a#fragment',
    ]) {await expectLater(openWorkBuddyAuthorization(Uri.parse(raw)),throwsA(anything));}
    expect(calls,0);
  });
}
