import 'dart:io';
import 'package:flutter/services.dart';
import 'zcode_accounts.dart';
import 'zcode_auth_file.dart';

/// Only the file picker/private app directory need Cocoa. Parsing and backup
/// stay in the shared Dart code; no plugin, network, shell, or second runtime.
class MacFileBackup {
  static const _channel = MethodChannel('com.sailingloong.loongpass/files');
  const MacFileBackup();

  Future<String?> selectAndBackup() async {
    Object? selection;
    try {
      selection = await _channel.invokeMethod<Object?>('chooseBackupSource');
    } on PlatformException catch (error) {
      if (error.code == 'PrivateDirectoryRequired') {
        throw const AccountFailure('PrivateDirectoryRequired');
      }
      throw const AccountFailure('NativeBackupUnavailable');
    } catch (_) {
      throw const AccountFailure('NativeBackupUnavailable');
    }
    if (selection == null) return null;
    String? saved;
    try {
      if (selection is! Map ||
          selection['sourcePath'] is! String ||
          selection['privateRoot'] is! String ||
          (selection['sourcePath'] as String).isEmpty ||
          (selection['privateRoot'] as String).isEmpty) {
        throw const AccountFailure('InvalidSelection');
      }
      saved = (await ZcodeAuthFile.backup(
        File(selection['sourcePath'] as String),
        Directory(selection['privateRoot'] as String),
      )).path;
      return saved;
    } finally {
      try {
        await _channel.invokeMethod<void>('releaseBackupSource');
      } catch (_) {
        throw AccountFailure(
          saved == null ? 'NativeCleanupFailed' : 'BackupSavedCleanupFailed',
        );
      }
    }
  }

  Future<void> reveal(String path) async {
    try {
      await _channel.invokeMethod<void>('revealBackup', {'path': path});
    } catch (_) {
      throw const AccountFailure('RevealUnavailable');
    }
  }
}
