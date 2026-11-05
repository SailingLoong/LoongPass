import 'dart:io';
import 'package:flutter/services.dart';
import 'qoder_claim.dart';
import 'qoder_pat_import.dart';

/// Keep the system-picked file's read-only grant until selection and parsing end.
/// No credentials or paths are sent back over the platform channel.
class MacQoderImport {
  static const _channel = MethodChannel('com.sailingloong.loongpass/files');
  const MacQoderImport();

  Future<QoderPatCandidate?> select(
    Future<String?> Function(List<String>) choose,
  ) async {
    Object? path;
    try {
      path = await _channel.invokeMethod<Object?>('chooseQoderImportSource');
    } catch (_) {
      throw const QoderFailure('NativeImportUnavailable');
    }
    if (path == null) return null;
    try {
      if (path is! String || !path.startsWith('/') || path.contains('\u0000'))
        throw const QoderFailure('InvalidSelection');
      final file = File(path);
      return await QoderPatImport.select(file, choose);
    } finally {
      try {
        await _channel.invokeMethod<void>('releaseSelectedSource');
      } catch (_) {
        throw const QoderFailure('NativeImportCleanupFailed');
      }
    }
  }
}
