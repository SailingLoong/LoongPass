import 'package:flutter/services.dart';
import 'native_account_document_store.dart';
import 'zcode_activity_accounts.dart';
import 'zcode_api.dart';

Future<String?> verifyNativeZcodeClaim(ZcodeCaptchaConfig config) async {
  try {
    return await const MethodChannel(
      'com.sailingloong.loongpass/files',
    ).invokeMethod<String>('verifyZcodeClaim', config.values);
  } catch (_) {
    throw const ZcodeFailure('verification_unavailable');
  }
}

ZcodeActivityAccounts createNativeZcodeActivityAccounts() =>
    ZcodeActivityAccounts(
      store: NativeAccountDocumentStore('ZCode'),
      api: ZcodeApi(ZcodeHttp()),
      requestVerification: verifyNativeZcodeClaim,
    );
