import 'package:flutter/services.dart';

import 'zcode_api.dart';

Future<String?> verifyNativeZcodeClaim(ZcodeCaptchaConfig config) async {
  try {
    return await const MethodChannel('com.sailingloong.loongpass/files')
        .invokeMethod<String>('verifyZcodeClaim', config.values);
  } catch (_) {
    throw const ZcodeFailure('verification_unavailable');
  }
}
