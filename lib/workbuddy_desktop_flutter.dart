import 'package:flutter/services.dart';

import 'workbuddy_desktop_session.dart';

class WorkBuddyDesktopFlutter {
  static const _channel = MethodChannel('com.sailingloong.loongpass/files');

  static Future<String> clientVersion() async {
    try {
      final version = await _channel.invokeMethod<String>(
        'workBuddyClientVersion',
      );
      if (version == null) throw StateError('unavailable');
      return version;
    } catch (_) {
      throw StateError('WorkBuddy client version unavailable');
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
