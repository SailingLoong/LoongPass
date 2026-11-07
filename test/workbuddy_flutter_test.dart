import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loongpass/workbuddy_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.sailingloong.loongpass/files');
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  test('memory owner prepares only the private claim journal', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return Directory.fromUri(
            Directory.systemTemp.uri.resolve('loongpass-synthetic-workbuddy/'),
          ).path;
        });
    final owner = await createWorkBuddyMemoryOwner();
    expect(calls.map((c) => c.method), ['prepareWorkBuddyJournal']);
    owner.close();
  });
  test('official authorization opens through the native allowlist', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    await openWorkBuddyAuthorization(
      Uri.parse('https://www.codebuddy.cn/authorize?state=synthetic'),
    );
    expect(calls.map((c) => c.method), ['openWorkBuddyAuthorization']);
  });
  test('invalid authorization never reaches native browser', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          return null;
        });
    for (final raw in [
      'https://evil.test/authorize?state=synthetic',
      'http://www.codebuddy.cn/authorize?state=synthetic',
      'https://www.codebuddy.cn/authorize?state=a&state=b',
      'https://www.codebuddy.cn/authorize?state=a&token=secret',
      'https://www.codebuddy.cn/authorize?state=',
      'https://www.codebuddy.cn/authorize?state=a#fragment',
    ]) {
      await expectLater(
        openWorkBuddyAuthorization(Uri.parse(raw)),
        throwsA(anything),
      );
    }
    expect(calls, 0);
  });
}
