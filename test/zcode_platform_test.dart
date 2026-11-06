import 'package:flutter_test/flutter_test.dart';
import '../lib/zcode_api.dart';

void main() {
  final context = <String, dynamic>{
    'version': '3.17.2',
    'platform': 'win32-x64',
    'deviceMid': '00112233-4455-4677-8899-aabbccddeeff',
    'language': 'zh-CN',
    'timezone': 'Asia/Shanghai',
  };
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
