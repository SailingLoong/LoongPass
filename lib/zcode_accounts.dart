// Adapted from SailingLoong/LoongPort zcode_accounts/core.rs at
// 9e1b7e574e1ca923d8ee5aab3cd7ede16a8872b6 (MIT; see LICENSE).
// Copyright (c) 2025 Jason Young; Copyright (c) 2026 SailingLoong.
// Pure same-machine decisions, directly usable in Flutter without another runtime.
// The native adapter must authenticate identity and strictly parse the source
// before calling this library. This does not read, decrypt, or write credentials.
import 'dart:convert';

const _maxDocumentBytes = 4 * 1024 * 1024;

class AccountFailure implements Exception {
  final String code;
  const AccountFailure(this.code);
  @override
  String toString() => code;
}

class AccountIdentity {
  final String _context;
  final String _family;
  final String _accountId;
  AccountIdentity._(this._context, this._family, this._accountId);

  factory AccountIdentity(String context, String family, String accountId) {
    final normalized = _jsTrim(accountId);
    if (_jsTrim(context).isEmpty ||
        !_wellFormed(context) ||
        !_wellFormed(normalized) ||
        normalized.isEmpty ||
        normalized == 'unknown' ||
        !['zai', 'bigmodel'].contains(family)) {
      throw const AccountFailure('InvalidIdentity');
    }
    return AccountIdentity._(context, family, normalized);
  }

  bool _sameAs(AccountIdentity other) =>
      _context == other._context &&
      _family == other._family &&
      _accountId == other._accountId;

  List<String> get _keys {
    final account = Uri.encodeComponent(_accountId);
    return [
      'oauth:active_provider',
      'oauth:$_family:access_token',
      'oauth:$_family:refresh_token',
      'oauth:$_family:user_info',
      'zcodejwttoken',
      'account-provider:coding-plan:account:$_family-individual-coding-plan:account:$account:api-key',
      'account-provider:start-plan:account:$_family-start-plan:account:$account:api-key',
    ];
  }
}

class AccountSnapshot {
  final AccountIdentity _identity;
  final Map<String, String?> _values;
  AccountSnapshot._(this._identity, Map<String, String?> values)
    : _values = Map.unmodifiable(values);

  /// Input must already be authenticated and parsed without duplicate keys.
  factory AccountSnapshot.capture(
    AccountIdentity identity,
    Map<String, String> document,
  ) => _capture(identity, _copyDocument(document));

  static AccountSnapshot _capture(
    AccountIdentity identity,
    Map<String, String> document,
  ) {
    final keys = identity._keys;
    for (final index in [0, 1, 3]) {
      if (document[keys[index]]?.isNotEmpty != true) {
        throw const AccountFailure('MissingSessionCredential');
      }
    }
    return AccountSnapshot._(identity, {
      for (final key in keys) key: document[key],
    });
  }
}

class SwitchPlan {
  final Map<String, String> _source;
  final AccountSnapshot _target;
  final AccountSnapshot backup;
  SwitchPlan._(Map<String, String> source, this._target, this.backup)
    : _source = Map.unmodifiable(source);

  /// Captures the fresh source before planning. The caller persists that backup
  /// before native writes and owns process, lock, revision, and rollback checks.
  factory SwitchPlan.prepare(
    AccountIdentity currentIdentity,
    Map<String, String> current,
    AccountSnapshot target,
  ) {
    if (currentIdentity._context != target._identity._context) {
      throw const AccountFailure('DifferentContext');
    }
    if (currentIdentity._family != target._identity._family) {
      throw const AccountFailure('DifferentFamily');
    }
    final source = _copyDocument(current);
    final backup = AccountSnapshot._capture(currentIdentity, source);
    return SwitchPlan._(
      source,
      currentIdentity._sameAs(target._identity) ? backup : target,
      backup,
    );
  }

  bool get isNoop => backup._identity._sameAs(_target._identity);

  Map<String, String> apply(Map<String, String> current) {
    final next = _copyDocument(current);
    if (next.length != _source.length ||
        _source.entries.any((entry) => next[entry.key] != entry.value)) {
      throw const AccountFailure('SourceChanged');
    }
    if (isNoop) return next;
    for (final entry in _target._values.entries) {
      final value = entry.value;
      if (value == null) {
        next.remove(entry.key);
      } else {
        next[entry.key] = value;
      }
    }
    return _copyDocument(next);
  }
}

Map<String, String> _copyDocument(Map<String, String> input) {
  final copy = Map<String, String>.from(input);
  if (copy.entries.any((e) => !_wellFormed(e.key) || !_wellFormed(e.value))) {
    throw const AccountFailure('InvalidDocument');
  }
  if (utf8.encode(jsonEncode(copy)).length > _maxDocumentBytes) {
    throw const AccountFailure('DocumentTooLarge');
  }
  return copy;
}

// Dart trim also strips U+0085; ZCode uses the ECMAScript whitespace set.
final _jsWhitespace = RegExp(
  r'^[\u0009-\u000D\u0020\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]+|[\u0009-\u000D\u0020\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]+$',
);
String _jsTrim(String value) => value.replaceAll(_jsWhitespace, '');

bool _wellFormed(String value) {
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i == value.length) return false;
      final low = value.codeUnitAt(i);
      if (low < 0xdc00 || low > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}
