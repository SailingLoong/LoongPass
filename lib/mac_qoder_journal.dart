import 'dart:io';
import 'package:flutter/services.dart';
import 'qoder_claim.dart';
import 'qoder_journal.dart';

/// Native code chooses/validates the private app directory and fsyncs directories
/// only. It must never open/close the journal inode while Dart holds its POSIX lock.
class MacQoderJournal {
  static const _channel = MethodChannel('com.sailingloong.loongpass/files');
  static Future<QoderAttemptJournal> open() async {
    try {
      final path = await _channel.invokeMethod<Object?>('prepareQoderJournal');
      if (path is! String || !path.startsWith('/') || path.contains('\u0000'))
        throw const QoderFailure('NativeJournalUnavailable');
      return QoderAttemptJournal(
        Directory(path),
        syncDirectory: () async {
          try {
            await _channel.invokeMethod<void>('syncQoderJournal');
          } catch (_) {
            throw const QoderFailure('NativeJournalUnavailable');
          }
        },
      );
    } catch (_) {
      throw const QoderFailure('NativeJournalUnavailable');
    }
  }
}
