import 'package:flutter/services.dart';

import 'workbuddy_desktop_session.dart';
import 'workbuddy_client_info.dart';

class WorkBuddyDesktopFlutter {
  static const _channel = MethodChannel('com.sailingloong.loongpass/files');

  static Future<WorkBuddyClientInfo> clientInfo() async {
    try {
      final info = await _channel.invokeMethod<Object>('workBuddyClientInfo');
      return WorkBuddyClientInfo.fromNative(info);
    } catch (_) {
      throw StateError('WorkBuddy client info unavailable');
    }
  }

  static Future<String> activate(WorkBuddyDesktopSession session) async {
    try {
      final result = await _channel.invokeMethod<String>(
        'activateWorkBuddyDesktop',
        session.nativeMessage(),
      );
      return {
            'opened',
            'applied',
            'cancelled',
            'expired',
            'unavailable',
            'busy',
            'recoveryRequired',
          }.contains(result)
          ? result!
          : 'unknown';
    } catch (_) {
      // A native error may follow a committed write. Keep its outcome unknown
      // and keep platform messages or credential-bearing arguments private.
      return 'unknown';
    }
  }
}
