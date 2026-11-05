// Adapted from SailingLoong/LoongPort workbuddy/credits.rs (MIT), originally
// workbuddy-switch credits.rs, Copyright (c) 2026 wb-switch.
// Copyright (c) 2025 Jason Young; Copyright (c) 2026 SailingLoong.
// Pure normalization only: no credentials, HTTP, persistence or signatures.

import 'credit_summary.dart';
export 'credit_summary.dart';

double? normalizeWorkBuddyBalance(
  Map<String, Object?> summary,
  Map<String, Object?> paid,
  Map<String, Object?> free, {
  required DateTime now,
}) => normalizeWorkBuddyCredits(summary, paid, free, now: now)?.totalRemaining;

/// A complete total from all three pinned single-page resource responses.
/// Null means incomplete or uncertain, never a partial sum. The caller owns
/// exact account/generation binding and a same-China-day observation boundary.
/// Details supersede summary aggregates even when sequential values differ.
CreditSummary? normalizeWorkBuddyCredits(
  Map<String, Object?> summary,
  Map<String, Object?> paid,
  Map<String, Object?> free, {
  required DateTime now,
}) {
  try {
    final summaries = _rows(summary, 'Packages');
    final details = [..._rows(paid, 'Accounts'), ..._rows(free, 'Accounts')];
    final seen = <String, Map>{};
    final detailCodes = <String>{};
    final records = <Map>[];
    for (final raw in details) {
      if (_number(raw['CapacityType']) == 4) continue;
      final id = _first(raw, ['ResourceId', 'resourceId']);
      if (id is String && id.isNotEmpty) {
        final previous = seen[id];
        if (previous != null) {
          if (!_same(previous, raw)) _unknown();
          continue;
        }
        seen[id] = raw;
      }
      final code = _first(raw, ['PackageCode', 'packageCode']);
      if (code is String) detailCodes.add(code);
      records.add(raw);
    }
    final summaryCodes = <String>{};
    for (final raw in summaries) {
      if (_number(raw['CapacityType']) == 4) continue;
      final code = _first(raw, ['PackageCode', 'packageCode']);
      if (code is String && detailCodes.contains(code)) continue;
      // Repeated aggregate rows cannot safely establish a distinct resource.
      if (code is String && code.isNotEmpty && !summaryCodes.add(code))
        _unknown();
      records.add(raw);
    }
    final current = now.toUtc().millisecondsSinceEpoch;
    var total = 0.0, undated = 0.0;
    final batches = <int, double>{};
    for (final raw in records) {
      final expiry = _expiry(raw);
      if (expiry != null && expiry <= current) continue;
      final remaining = _remaining(raw);
      if (remaining == null) _unknown();
      total += remaining;
      if (remaining > 0) {
        if (expiry == null) {
          undated += remaining;
        } else {
          batches[expiry] = (batches[expiry] ?? 0) + remaining;
        }
      }
      if (!total.isFinite) _unknown();
    }
    final dates = batches.keys.toList()..sort();
    return CreditSummary(total, undated, now.toUtc(), [
      for (final date in dates)
        CreditExpiry(
          DateTime.fromMillisecondsSinceEpoch(date, isUtc: true),
          batches[date]!,
        ),
    ]);
  } on _UnknownBalance {
    return null;
  }
}

class _UnknownBalance {
  const _UnknownBalance();
}

Never _unknown() => throw const _UnknownBalance();
Object? _first(Map value, List<String> keys) {
  for (final key in keys) {
    if (value.containsKey(key)) return value[key];
  }
  return null;
}

double? _number(Object? value) {
  final n = value is num
      ? value.toDouble()
      : value is String
      ? double.tryParse(value.trim())
      : null;
  return n != null && n.isFinite && n >= 0 ? n : null;
}

double? _firstNumber(Map value, List<String> keys) {
  for (final key in keys) {
    final n = _number(value[key]);
    if (n != null) return n;
  }
  return null;
}

double? _remaining(Map raw) {
  const remaining = [
    'CapacityRemainPrecise',
    'CapacityRemain',
    'CycleCapacityRemainPrecise',
    'CycleCapacityRemain',
    'CycleRemainCapacity',
  ];
  if (remaining.any(raw.containsKey)) return _firstNumber(raw, remaining);
  final total = _firstNumber(raw, [
    'CapacitySizePrecise',
    'CapacitySize',
    'CycleCapacitySizePrecise',
    'CycleCapacitySize',
    'CycleTotalCapacity',
  ]);
  final used = _firstNumber(raw, [
    'CapacityUsedPrecise',
    'CapacityUsed',
    'CycleCapacityUsedPrecise',
    'CycleCapacityUsed',
    'CycleUsedCapacity',
  ]);
  return total != null && used != null && used <= total ? total - used : null;
}

List<Map> _rows(Map<String, Object?> response, String field) {
  if (![0, 200, '0', '200'].contains(response['code'])) _unknown();
  List? selected;
  for (final path in [
    ['data'],
    ['data', 'data'],
    ['data', 'Response', 'Data'],
    ['data', 'data', 'Response', 'Data'],
  ]) {
    Object? value = response;
    for (final key in path) {
      value = value is Map ? value[key] : null;
    }
    if (value is! Map) continue;
    final lower = field.toLowerCase();
    if (!value.containsKey(field) && !value.containsKey(lower)) continue;
    if (value.containsKey(field) &&
        value.containsKey(lower) &&
        !_same(value[field], value[lower]))
      _unknown();
    final rows = _first(value, [field, lower]);
    if (rows is! List || rows.any((row) => row is! Map)) _unknown();
    final count = _first(value, ['TotalCount', 'totalCount']);
    if (value.containsKey('TotalCount') || value.containsKey('totalCount')) {
      if (value.containsKey('TotalCount') &&
          value.containsKey('totalCount') &&
          _number(value['TotalCount']) != _number(value['totalCount']))
        _unknown();
      if (_number(count) != rows.length) _unknown();
    } else if (rows.length >= 200) {
      _unknown();
    }
    // More than one recognized envelope must describe the same rows.
    if (selected != null && !_same(selected, rows)) _unknown();
    selected = rows;
  }
  if (selected == null) _unknown();
  return selected.cast<Map>();
}

bool _same(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _same(a[key], b[key]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        Iterable<int>.generate(a.length).every((i) => _same(a[i], b[i]));
  }
  return a == b;
}

int? _expiry(Map raw) {
  final end = _timestamp(
    _first(raw, [
      'DeductionEndTime',
      'deductionEndTime',
      'ExpiredTime',
      'expiredTime',
    ]),
  );
  final cycle = _timestamp(_first(raw, ['CycleEndTime', 'cycleEndTime']));
  if (end != null && cycle != null && end - cycle > 365 * 24 * 3600 * 1000) {
    return cycle;
  }
  return end ?? cycle;
}

int? _timestamp(Object? raw) {
  if (raw == null)
    return null; // Absent expiry is active in the pinned contract.
  final numeric = _number(raw);
  if (numeric != null) {
    final millis = numeric < 10000000000 ? numeric * 1000 : numeric;
    if (millis <= 0 || millis >= 9223372036854775807) _unknown();
    return millis.round();
  }
  // Stricter than the source: an explicit invalid date is unknown, not active.
  // Parse components before applying offsets; Dart's permissive date rollover
  // and host-local timezone must not turn malformed/China dates into evidence.
  if (raw is! String) _unknown();
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})?)?$',
    caseSensitive: false,
  ).firstMatch(raw);
  if (match == null) _unknown();
  final year = int.parse(match[1]!),
      month = int.parse(match[2]!),
      day = int.parse(match[3]!);
  final hour = match[4] == null ? 23 : int.parse(match[4]!);
  final minute = match[5] == null ? 59 : int.parse(match[5]!);
  final second = match[6] == null ? 59 : int.parse(match[6]!);
  final millis = int.parse((match[7] ?? '').padRight(3, '0').substring(0, 3));
  final date = DateTime.utc(year, month, day, hour, minute, second, millis);
  if (date.year != year ||
      date.month != month ||
      date.day != day ||
      date.hour != hour ||
      date.minute != minute ||
      date.second != second)
    _unknown();
  final zone = match[8];
  var offset = 8 * 60;
  if (zone != null) {
    if (zone.toUpperCase() == 'Z') {
      offset = 0;
    } else {
      final hours = int.parse(zone.substring(1, 3));
      final minutes = int.parse(zone.substring(4, 6));
      if (hours > 23 || minutes > 59) _unknown();
      offset = (hours * 60 + minutes) * (zone[0] == '-' ? -1 : 1);
    }
  }
  return date.millisecondsSinceEpoch - offset * 60 * 1000;
}
