// Narrow import of LoongPort's existing Provider/plaintext-export JSON shapes.
// Source: 9e1b7e574e1ca923d8ee5aab3cd7ede16a8872b6 (MIT; see LICENSE).
import 'dart:convert';
import 'dart:io';
import 'qoder_claim.dart';

/// An unverified in-memory candidate, not an authenticated account or permission
/// to claim. The caller must ask for the source declaration and authenticate it.
/// Foreign generation, automatic permission and pending state are never adopted.
class QoderPatCandidate {
  final String providerId;
  final String _personalToken;
  const QoderPatCandidate._(this.providerId, this._personalToken);

  /// Only the authentication adapter should consume this value. Do not log,
  /// serialize, include it in a URL, or save it in the non-secret attempt log.
  T useForVerification<T>(T Function(String) consume) =>
      consume(_personalToken);
  @override
  String toString() => 'QoderPatCandidate(redacted)';
}

class QoderPatImport {
  /// Bind the chosen provider to one document read. A later source replacement
  /// while the selection dialog is open cannot substitute another credential.
  /// The document remains local to this call and is never logged or persisted.
  static Future<QoderPatCandidate?> select(
    File file,
    Future<String?> Function(List<String>) choose,
  ) async {
    final document = await _readDocument(file);
    final ids = _listProviderIds(document);
    final selected = ids.length == 1 ? ids.single : await choose(ids);
    if (selected == null) return null;
    if (!ids.contains(selected)) throw const QoderFailure('ProviderNotFound');
    return _selected(document, selected);
  }

  /// Inspect only the explicitly chosen document. Return safe identifiers, never
  /// token values, names from unrelated accounts, or imported authorization.
  static Future<List<String>> listProviderIds(File file) async =>
      _listProviderIds(await _readDocument(file));

  static List<String> _listProviderIds(Map<String, dynamic> data) {
    final ids = <String>[];
    if (data.containsKey('database')) {
      final database = data['database'];
      if (data.containsKey('settingsConfig') ||
          database is! Map ||
          database['providers'] is! List)
        throw const QoderFailure('InvalidImport');
      final rows = (database['providers'] as List)
          .whereType<Map>()
          .where((row) => row['app_type'] == 'codex')
          .toList();
      final counts = <Object?, int>{};
      for (final row in rows) {
        counts[row['id']] = (counts[row['id']] ?? 0) + 1;
      }
      for (final row in rows) {
        final raw = row['meta'];
        final meta = raw is String ? decodeQoderObject(raw) : null;
        // Unrelated/unsupported records do not make a supported selection unusable.
        if (meta == null || meta['providerType'] != 'qoder_sdk') continue;
        final id = row['id'];
        _requireId(id);
        if (counts[id] != 1) throw const QoderFailure('AmbiguousProvider');
        try {
          _selected({
            'database': {
              'providers': [row],
            },
          }, id as String);
        } on QoderFailure catch (error) {
          if (error.code == 'UnsupportedCredentialSource') continue;
          rethrow;
        }
        ids.add(id);
      }
    } else {
      final id = data['id'];
      _requireId(id);
      _selected(data, id as String);
      ids.add(id);
    }
    if (ids.isEmpty) throw const QoderFailure('UnsupportedCredentialSource');
    return List.unmodifiable(ids);
  }

  static void _requireId(Object? id) {
    if (id is! String || !RegExp(r'^[A-Za-z0-9_.:-]{1,256}$').hasMatch(id))
      throw const QoderFailure('InvalidProviderId');
  }

  /// Read only the explicitly selected existing file. No discovery, environment,
  /// keychain access, copying, credential persistence or network activity.
  /// Size/mtime and post-read link checks catch ordinary replacement; this Dart
  /// reader does not pin inode identity against a hostile same-user process.
  static Future<QoderPatCandidate> read(
    File selectedFile, {
    required String providerId,
  }) async {
    _requireId(providerId);
    return _selected(await _readDocument(selectedFile), providerId);
  }

  static Future<Map<String, dynamic>> _readDocument(File selectedFile) async {
    try {
      if (await FileSystemEntity.type(selectedFile.path, followLinks: false) !=
          FileSystemEntityType.file)
        throw const QoderFailure('ImportUnavailable');
      final before = await selectedFile.stat();
      if (before.size > 1024 * 1024) throw const QoderFailure('InvalidImport');
      final handle = await selectedFile.open();
      late List<int> bytes;
      try {
        bytes = await handle.read(1024 * 1024 + 1);
      } finally {
        await handle.close();
      }
      final after = await selectedFile.stat();
      if (await FileSystemEntity.type(selectedFile.path, followLinks: false) !=
              FileSystemEntityType.file ||
          bytes.length > 1024 * 1024 ||
          before.size != bytes.length ||
          before.size != after.size ||
          before.modified != after.modified)
        throw const QoderFailure('InvalidImport');
      Map<String, dynamic>? data;
      try {
        data = decodeQoderObject(utf8.decode(bytes, allowMalformed: false));
      } catch (_) {
        throw const QoderFailure('InvalidImport');
      }
      if (data == null) throw const QoderFailure('InvalidImport');
      return data;
    } catch (error) {
      if (error is QoderFailure) rethrow;
      throw const QoderFailure('ImportUnavailable');
    }
  }

  static QoderPatCandidate _selected(Map data, String id) {
    Map? settings, meta;
    if (data.containsKey('database')) {
      if (data.containsKey('settingsConfig'))
        throw const QoderFailure('InvalidImport');
      final database = data['database'];
      if (database is! Map || database['providers'] is! List)
        throw const QoderFailure('InvalidImport');
      final matchingIds = (database['providers'] as List)
          .whereType<Map>()
          .where((row) => row['id'] == id)
          .toList();
      if (matchingIds.isEmpty) throw const QoderFailure('ProviderNotFound');
      final rows = matchingIds
          .where((row) => row['app_type'] == 'codex')
          .toList();
      if (rows.isEmpty) throw const QoderFailure('UnsupportedCredentialSource');
      if (rows.length != 1) throw const QoderFailure('AmbiguousProvider');
      final row = rows.single;
      if (row['settings_config'] is! String || row['meta'] is! String)
        throw const QoderFailure('InvalidImport');
      settings = decodeQoderObject(row['settings_config'] as String);
      meta = decodeQoderObject(row['meta'] as String);
    } else {
      if (data['id'] != id) throw const QoderFailure('ProviderNotFound');
      if (data['settingsConfig'] is Map)
        settings = data['settingsConfig'] as Map;
      if (data['meta'] is Map) meta = data['meta'] as Map;
    }
    if (settings == null || meta == null)
      throw const QoderFailure('InvalidImport');
    if (meta['providerType'] != 'qoder_sdk')
      throw const QoderFailure('UnsupportedCredentialSource');
    final binding = meta['authBinding'];
    if (binding != null &&
        (binding is! Map ||
            binding.containsKey('source') &&
                binding['source'] != 'provider_config'))
      throw const QoderFailure('UnsupportedCredentialSource');
    // Deliberately narrower than the legacy TOML/config fallback parser.
    if (settings.containsKey('config'))
      throw const QoderFailure('UnsupportedCredentialSource');
    final candidates = <String>{};
    void take(Object? value) {
      if (value is! String)
        throw const QoderFailure('UnsupportedCredentialSource');
      final token = value.trim();
      if (token.isEmpty ||
          token.length > 8192 ||
          token.codeUnits.any(
            (unit) => unit < 0x21 || unit > 0x7e || unit == 0x24,
          ))
        throw const QoderFailure('UnsupportedCredentialSource');
      candidates.add(token);
    }

    for (final group in ['env', 'auth']) {
      final value = settings[group];
      if (value != null && value is! Map)
        throw const QoderFailure('UnsupportedCredentialSource');
      if (value is Map && value.containsKey('OPENAI_API_KEY'))
        take(value['OPENAI_API_KEY']);
    }
    for (final key in ['apiKey', 'api_key']) {
      if (settings.containsKey(key)) take(settings[key]);
    }
    if (candidates.isEmpty)
      throw const QoderFailure('UnsupportedCredentialSource');
    if (candidates.length != 1) throw const QoderFailure('AmbiguousCredential');
    return QoderPatCandidate._(id, candidates.single);
  }
}
