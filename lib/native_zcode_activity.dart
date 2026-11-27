import 'package:flutter/services.dart';

import 'zcode_api.dart';

const _files = MethodChannel('com.sailingloong.loongpass/files');

/// Reuse the official client's observed device on this computer.
Future<String?> installedZcodeDevice() async {
  try {
    final context = await _files.invokeMapMethod<String, dynamic>(
      'zcodeRequestContext',
    );
    return context == null ? null : zcodeDeviceId(context['deviceMid']);
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  } on ZcodeFailure {
    return null;
  }
}

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
