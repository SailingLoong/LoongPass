// Strict document rules adapted from LoongPort zcode_accounts/core.rs at
// 9e1b7e574e1ca923d8ee5aab3cd7ede16a8872b6 (MIT; see LICENSE).
// Copyright (c) 2025 Jason Young; Copyright (c) 2026 SailingLoong.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'zcode_accounts.dart';

const _limit = 4 * 1024 * 1024;

/// Explicit-file operations only. Never finds or overwrites a client auth file.
/// Native identity/OS-context verification and encrypted value handling remain
/// the caller's responsibility. This is not a native account-switch adapter.
class ZcodeAuthFile {
  /// Copies the complete original bytes into a fresh directory inside an owner-only root.
  /// The caller supplies an existing private destination on this same machine.
  /// No new encryption or credentials are introduced. Windows ACLs are not yet
  /// validated, so backup fails closed there. POSIX mode is not an ACL audit.
  static Future<File> backup(File source, Directory privateRoot) async {
    if (!Platform.isLinux && !Platform.isMacOS) {
      throw const AccountFailure('PlatformNotValidated');
    }
    Directory? created;
    try {
      await _requirePrivate(privateRoot);
      final original = await _read(source);
      _parse(original);
      created = await privateRoot.createTemp('loongpass-');
      final saved = File('${created.path}${Platform.pathSeparator}auth.json');
      await saved.create(exclusive: true);
      await saved.writeAsBytes(original, flush: true);
      if (!_equal(await _read(saved), original)) {
        throw const AccountFailure('BackupVerificationFailed');
      }
      if (!_equal(await _read(source), original)) {
        throw const AccountFailure('SourceChanged');
      }
      await _requirePrivate(privateRoot);
      return saved;
    } catch (error) {
      if (created != null) {
        try {
          // Only the fresh directory owned by this operation, never the source.
          await created.delete(recursive: true);
        } on FileSystemException {
          throw const AccountFailure('IncompleteBackupCleanupRequired');
        }
      }
      if (error is AccountFailure) rethrow;
      throw const AccountFailure('FileAccessFailed');
    }
  }

  /// Re-imports a strict document into the existing seven-field snapshot core.
  /// A snapshot is not proof of authentication. Values may still be native
  /// ciphertext; this function does not decrypt them or validate a live login.
  static Future<AccountSnapshot> import(
    File source,
    AccountIdentity verifiedIdentity,
  ) async =>
      AccountSnapshot.capture(verifiedIdentity, _parse(await _read(source)));
}

Future<void> _requirePrivate(Directory directory) async {
  try {
    // Do not lexically normalize away link/..: the OS would resolve that path
    // differently. Validate the same absolute path used for the actual write.
    final normalized = directory.absolute.path;
    final absolute = Directory(
      normalized.endsWith('/')
          ? normalized.substring(0, normalized.length - 1)
          : normalized,
    );
    if (await FileSystemEntity.type(absolute.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await absolute.resolveSymbolicLinks() != absolute.path ||
        (await absolute.stat()).mode & 0x3f != 0) {
      throw const AccountFailure('PrivateDirectoryRequired');
    }
  } on FileSystemException {
    throw const AccountFailure('PrivateDirectoryRequired');
  }
}

Future<Uint8List> _read(File file) async {
  try {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const AccountFailure('InvalidFile');
    }
    final before = await file.stat();
    if (before.size > _limit) {
      throw const AccountFailure('DocumentTooLarge');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > _limit) {
        throw const AccountFailure('DocumentTooLarge');
      }
      bytes.add(chunk);
    }
    final after = await file.stat();
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        before.size != after.size ||
        before.modified != after.modified ||
        bytes.length != after.size) {
      throw const AccountFailure('SourceChanged');
    }
    return bytes.takeBytes();
  } on FileSystemException {
    throw const AccountFailure('FileAccessFailed');
  }
}

bool _equal(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

Map<String, String> _parse(Uint8List bytes) {
  try {
    // Dart strips UTF-8 BOMs, while the original strict JSON parser rejects one.
    if (bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf) {
      throw const FormatException();
    }
    return _StringObject(utf8.decode(bytes, allowMalformed: false)).parse();
  } on FormatException {
    // Do not expose parser input, filesystem paths, or credential contents.
    throw const AccountFailure('InvalidDocument');
  }
}

// jsonDecode alone silently overwrites duplicate keys. Scan the small supported
// grammar, decode each quoted string with Dart's JSON parser, then check keys.
class _StringObject {
  final String text;
  var offset = 0;
  _StringObject(this.text);

  Map<String, String> parse() {
    final result = <String, String>{};
    _space();
    _expect('{');
    _space();
    if (!_take('}')) {
      while (true) {
        final key = _string();
        _space();
        _expect(':');
        _space();
        final value = _string();
        if (result.containsKey(key)) throw const FormatException();
        result[key] = value;
        _space();
        if (_take('}')) break;
        _expect(',');
        _space();
      }
    }
    _space();
    if (offset != text.length) throw const FormatException();
    return result;
  }

  String _string() {
    final start = offset;
    _expect('"');
    while (offset < text.length) {
      final char = text[offset++];
      if (char == r'\') {
        offset++;
      } else if (char == '"') {
        final value = jsonDecode(text.substring(start, offset)) as String;
        // Reject unpaired UTF-16 surrogates, matching serde_json's UTF-8 strings.
        for (var i = 0; i < value.length; i++) {
          final unit = value.codeUnitAt(i);
          if (unit >= 0xd800 && unit <= 0xdbff) {
            if (++i == value.length) throw const FormatException();
            final low = value.codeUnitAt(i);
            if (low < 0xdc00 || low > 0xdfff) throw const FormatException();
          } else if (unit >= 0xdc00 && unit <= 0xdfff) {
            throw const FormatException();
          }
        }
        return value;
      }
    }
    throw const FormatException();
  }

  void _space() {
    while (offset < text.length && ' \t\r\n'.contains(text[offset])) {
      offset++;
    }
  }

  bool _take(String value) {
    if (offset < text.length && text[offset] == value) {
      offset++;
      return true;
    }
    return false;
  }

  void _expect(String value) {
    if (!_take(value)) throw const FormatException();
  }
}
