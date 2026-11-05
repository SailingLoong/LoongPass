// Thin concrete wiring only. Importing this file does not enable a UI action.
import 'package:flutter/services.dart';

import 'zcode_native.dart';
import 'native_account_gate.dart';

class ZcodeMethodChannel {
  static const _channel = MethodChannel('com.sailingloong.loongpass/zcode');

  Future<Object?> call(String method, Map<String, Object?> arguments) async {
    if (!zcodeNativeAdapterValidated) {
      throw ZcodeNativeFailure.fromCode('NativeContextUnavailable');
    }
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      throw ZcodeNativeFailure.fromCode('NativeContextUnavailable');
    } on PlatformException catch (failure) {
      // Never retain PlatformException.message, details or native stack text.
      throw ZcodeNativeFailure.fromCode(failure.code);
    } catch (_) {
      throw ZcodeNativeFailure.fromCode('NativeUnavailable');
    }
  }
}

ZcodeNativeClient createZcodeNativeClient() =>
    ZcodeNativeClient(call: ZcodeMethodChannel().call);
