import 'package:flutter/services.dart';

import 'zcode_api.dart';

const _files = MethodChannel('com.sailingloong.loongpass/files');

Future<Map<String, String>> nativeZcodeActivityContext(
  Map<String, dynamic> grantContext,
  String language,
) async {
  final installed = await _files.invokeMethod<String>('zcodeClientVersion');
  return zcodeContext({
    ...grantContext,
    if (installed != null) 'version': installed,
    'language': language,
  });
}

Future<String?> verifyNativeZcodeClaim(ZcodeCaptchaConfig config) async {
  try {
    return await _files.invokeMethod<String>('verifyZcodeClaim', config.values);
  } catch (_) {
    throw const ZcodeFailure('verification_unavailable');
  }
}
