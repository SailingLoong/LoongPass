import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'magpie_connection.dart';

DateTime usageDate(DateTime value) {
  final local = value.toLocal();
  return DateTime(local.year, local.month, local.day);
}

String _isoDay(DateTime day) => day.toIso8601String().split('T').first;

class CallTotals {
  const CallTotals(this.calls, this.failed, this.input, this.output);
  final int calls, failed, input, output;

  factory CallTotals.fromJson(Map row) {
    int number(String key) {
      final n = row[key];
      if (n is int && n >= 0) return n;
      throw const FormatException('Incomplete Magpie totals');
    }

    return CallTotals(
      number('calls'),
      number('errors'),
      number('input'),
      number('output'),
    );
  }
}

typedef UsageHour = ({DateTime at, CallTotals totals});
typedef RecentCall = ({
  DateTime at,
  String account,
  String model,
  bool failed,
  bool canceled,
});

class UsageDay {
  const UsageDay(
    this.date,
    this.checkedAt,
    this.totals,
    this.hours,
    this.recent,
  );
  final DateTime date, checkedAt;
  final CallTotals totals;
  final List<UsageHour> hours;
  final List<RecentCall> recent;

  factory UsageDay.fromLedger(DateTime date, DateTime checkedAt, Map ledger) {
    final day = _isoDay(date);
    if (ledger['period'] != '$day..$day' ||
        ledger['provider'] != 'loongpass' ||
        ledger['bucket'] != 'hour' ||
        ledger['series'] is! List ||
        ledger['rows'] is! List) {
      throw const FormatException('Unsupported Magpie usage response');
    }
    final totals = CallTotals.fromJson(ledger);
    final hours = <UsageHour>[];
    for (final raw in ledger['series']) {
      if (raw is! Map) throw const FormatException();
      final at = DateTime.parse(raw['time'] as String).toLocal();
      if (usageDate(at) != date ||
          (hours.isNotEmpty && !at.isAfter(hours.last.at))) {
        throw const FormatException('Unexpected usage interval');
      }
      hours.add((at: at, totals: CallTotals.fromJson(raw)));
    }
    final nextDay = DateTime(date.year, date.month, date.day + 1);
    if (hours.isEmpty ||
        hours.first.at != date ||
        hours.length != (nextDay.difference(date).inMinutes / 60).ceil() ||
        hours.fold(0, (n, h) => n + h.totals.calls) != totals.calls) {
      throw const FormatException('Incomplete usage timeline');
    }
    final recent = <RecentCall>[];
    for (final row in ledger['rows']) {
      if (row is! Map ||
          row['provider'] != 'loongpass' ||
          row['handed_on'] == true ||
          row['rejected'] == true ||
          row['source'] == 'log' ||
          row['source'] == 'reported')
        continue;
      final model = [
        row['served'],
        row['model'],
      ].whereType<String>().where((s) => s.isNotEmpty).firstOrNull;
      final at = DateTime.tryParse(row['t']?.toString() ?? '')?.toLocal();
      if (at == null || usageDate(at) != date || model == null) continue;
      final canceled = row['canceled'] == true, status = row['status'];
      recent.add((
        at: at,
        account: row['providerAccount'] as String? ?? '',
        model: model,
        canceled: canceled,
        failed:
            !canceled &&
            ((status is int && status >= 400) ||
                (row['err'] is String && row['err'] != '')),
      ));
    }
    return UsageDay(
      date,
      checkedAt,
      totals,
      List.unmodifiable(hours),
      List.unmodifiable(recent),
    );
  }
}

/// Magpie owns counts, failure semantics and retry folding. Only read this
/// machine's gateway traffic attributed to the LoongPass provider.
class MagpieUsage extends ChangeNotifier {
  MagpieUsage({Future<Uri> Function()? locate, DateTime Function()? clock})
    : _locate = locate ?? MagpieConnection().localGateway,
      _clock = clock ?? DateTime.now;
  final Future<Uri> Function() _locate;
  final DateTime Function() _clock;
  final HttpClient _http = HttpClient();
  final _days = <DateTime, UsageDay>{};
  final _failed = <DateTime>{};
  Timer? _timer;
  bool _closed = false;
  Future<void>? _loading;
  DateTime get today => usageDate(_clock());
  DateTime get now => _clock();
  UsageDay? day(DateTime date) => _days[date];
  bool unavailable(DateTime date) => _failed.contains(date);
  List<DateTime> get dates {
    final d = today;
    return [for (var i = 6; i >= 0; i--) DateTime(d.year, d.month, d.day - i)];
  }

  void start() {
    if (_timer != null || _closed) return;
    _http.findProxy = (_) => 'DIRECT';
    _http.connectionTimeout = const Duration(seconds: 5);
    _timer = Timer.periodic(
      const Duration(minutes: 3),
      (_) => unawaited(refresh()),
    );
    unawaited(refresh());
  }

  Future<void> refresh() =>
      _loading ??= _refresh().whenComplete(() => _loading = null);
  Future<void> _refresh() async {
    final window = dates.reversed.toList();
    _days.removeWhere((d, _) => !window.contains(d));
    _failed.removeWhere((d) => !window.contains(d));
    try {
      final gateway = await _locate();
      for (final d in window) {
        if (_closed) return;
        final previous = _days[d];
        if (d != window.first &&
            previous != null &&
            !_failed.contains(d) &&
            usageDate(previous.checkedAt).isAfter(d) &&
            _clock().difference(previous.checkedAt) < const Duration(hours: 1))
          continue;
        try {
          final tag = _isoDay(d);
          final uri = gateway.replace(
            path: '/v1/magpie/usage/requests',
            queryParameters: {
              'period': '$tag..$tag',
              'provider': 'loongpass',
              'via': 'through',
              'computer': 'this',
              'limit': '6',
            },
          );
          final ledger = await _read(uri).timeout(const Duration(seconds: 12));
          _days[d] = UsageDay.fromLedger(d, _clock(), ledger);
          _failed.remove(d);
        } catch (_) {
          _failed.add(d);
        }
        if (!_closed) notifyListeners();
      }
    } catch (_) {
      _failed.addAll(window);
      if (!_closed) notifyListeners();
    }
  }

  Future<Map> _read(Uri uri) async {
    final req = await _http.getUrl(uri);
    req.followRedirects = false;
    final res = await req.close();
    if (res.statusCode != HttpStatus.ok) {
      await res.drain<void>();
      throw const FormatException('Usage unavailable');
    }
    final bytes = <int>[];
    await for (final chunk in res) {
      if (bytes.length + chunk.length > 4 << 20)
        throw const FormatException('Oversized ledger');
      bytes.addAll(chunk);
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map) throw const FormatException();
    return data;
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    _http.close(force: true);
    super.dispose();
  }
}
