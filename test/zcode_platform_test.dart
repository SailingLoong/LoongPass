import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/native_zcode_activity.dart';
import '../lib/zcode_api.dart';

void main() {
  final context = <String, dynamic>{
    'version': '3.17.2',
    'platform': 'win32-x64',
    'deviceMid': '00112233-4455-4677-8899-aabbccddeeff',
    'language': 'zh-CN',
    'timezone': 'Asia/Shanghai',
  };
  TestWidgetsFlutterBinding.ensureInitialized();
  test('activity queries use the installed version, current UI language and saved device', () async {
    const channel = MethodChannel('com.sailingloong.loongpass/files');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? installed = '3.18.2';
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'zcodeClientVersion');
      expect(call.arguments, isNull);
      return installed;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final plugin = {...context, 'version': '3.17.2', 'language': 'en-US'};
    expect(await nativeZcodeActivityContext(plugin, 'zh-CN'), {
      ...context,
      'version': '3.18.2',
    });
    installed = null;
    expect(await nativeZcodeActivityContext(plugin, 'zh-CN'), {
      ...context,
      'version': '3.17.2',
    });
  });
  test('Windows account context is accepted and keeps the bound device', () {
    expect(zcodeContext(context), context);
  });
  test('Mac-created saved contexts remain readable on the Windows host', () {
    for (final platform in ['darwin-arm64', 'darwin-x64']) {
      final saved = {...context, 'platform': platform};
      expect(zcodeContext(saved), saved);
    }
  });
}
