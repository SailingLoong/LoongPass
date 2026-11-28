import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'account_table_entry.dart';
import 'credit_expiry_history.dart';
import 'desktop_theme.dart';
import 'magpie_usage.dart';
import 'managed_app.dart';
import 'plugin_accounts.dart';
import 'workspace_page.dart';

part 'workspace_call_history.dart';

enum _Metric { calls, expiry }

String _dateText(DateTime date) =>
    '${date.toLocal().month} 月 ${date.toLocal().day} 日';
String _provider(String id) =>
    ManagedApp.values
        .where((a) => a.nativeProviders.contains(id))
        .firstOrNull
        ?.label ??
    id;

List<AccountExpiryRecord> _expired(PluginAccounts accounts, MagpieUsage usage) {
  final start = usage.dates.first, now = usage.now;
  return accounts.expiryHistory.where((r) {
    final b = r.batch, d = usageDate(b.at);
    final end = b.dateOnly ? DateTime(d.year, d.month, d.day + 1) : b.at;
    return !d.isBefore(start) && !end.isAfter(now);
  }).toList()..sort((a, b) => b.batch.at.compareTo(a.batch.at));
}

Map<(String, String), num> _amounts(Iterable<AccountExpiryRecord> rows) {
  final totals = <(String, String), num>{};
  for (final r in rows) {
    final n = r.batch.unused;
    if (n != null)
      totals.update(
        (r.provider, r.batch.unit),
        (v) => v + n,
        ifAbsent: () => n,
      );
  }
  return totals;
}

String _quantity(num value) => accountPoints(value).replaceFirstMapped(
  RegExp(r'^\d+'),
  (m) =>
      m[0]!.replaceAllMapped(RegExp(r'\d(?=(?:\d{3})+$)'), (d) => '${d[0]},'),
);

String _expirySummary(List<AccountExpiryRecord> records) {
  final known = records.where((r) => r.batch.unused != null);
  final pending = records.length - known.length;
  if (known.isEmpty) return pending == 0 ? '暂无已确认记录' : '$pending 批待核实';
  final losses = known.where((r) => r.batch.unused! > 0);
  final amounts = _amounts(losses.isEmpty ? known : losses);
  final String confirmed;
  if (amounts.length == 1) {
    final e = amounts.entries.single;
    confirmed = '${_quantity(e.value)} ${e.key.$2} · ${_provider(e.key.$1)}';
  } else {
    confirmed = losses.isEmpty ? '已核实的额度均已用完' : '${losses.length} 批已确认';
  }
  return pending == 0 ? confirmed : '$confirmed · $pending 批待核实';
}

class WorkspaceUsageSummary extends StatelessWidget {
  const WorkspaceUsageSummary({
    super.key,
    required this.usage,
    required this.accounts,
  });
  final MagpieUsage usage;
  final PluginAccounts accounts;
  void _open(BuildContext context, _Metric metric) =>
      Navigator.of(context).push<void>(
        PageRouteBuilder<void>(
          settings: const RouteSettings(name: '/overview/usage'),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (_, a, b) => _UsagePage(usage, accounts, metric),
        ),
      );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([usage, accounts]),
    builder: (context, _) {
      final today = usage.day(usage.today);
      Widget tile(_Metric metric, String label, String value) => FTile(
        title: Text(label),
        subtitle: Text(
          value,
          style: context.theme.typography.body.lg.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        suffix: const Icon(FLucideIcons.chevronRight, size: 15),
        onPress: () => _open(context, metric),
      );
      final calls = tile(
        _Metric.calls,
        '今日调用',
        today == null
            ? (usage.unavailable(usage.today) ? '暂不可用' : '读取中…')
            : '${today.totals.calls} 次${usage.unavailable(usage.today) ? ' · 上次记录' : ''}',
      );
      final expiry = tile(
        _Metric.expiry,
        '近 7 天到期未用',
        _expirySummary(_expired(accounts, usage)),
      );
      return Padding(
        padding: const EdgeInsets.only(top: 14),
        child: LayoutBuilder(
          builder: (context, box) =>
              box.maxWidth < 440 * MediaQuery.textScalerOf(context).scale(1)
              ? Column(children: [calls, expiry])
              : Row(
                  children: [
                    Expanded(child: calls),
                    Expanded(child: expiry),
                  ],
                ),
        ),
      );
    },
  );
}

class _UsagePage extends StatefulWidget {
  const _UsagePage(this.usage, this.accounts, this.initial);
  final MagpieUsage usage;
  final PluginAccounts accounts;
  final _Metric initial;
  @override
  State<_UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<_UsagePage> {
  late _Metric metric = widget.initial;
  late DateTime? selected = metric == _Metric.calls ? widget.usage.today : null;
  void select(DateTime? day) => setState(() => selected = day);
  Widget choice(String label, bool active, VoidCallback click) => FButton(
    variant: active ? FButtonVariant.primary : FButtonVariant.outline,
    size: FButtonSizeVariant.sm,
    mainAxisSize: MainAxisSize.min,
    onPress: click,
    child: Text(label),
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.usage, widget.accounts]),
    builder: (context, _) {
      final usage = widget.usage, dates = usage.dates;
      final date = selected == null
          ? null
          : (dates.contains(selected) ? selected : usage.today);
      return WorkspacePage(
        title: '用量明细',
        action: FButton(
          variant: FButtonVariant.ghost,
          size: FButtonSizeVariant.sm,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(),
          child: const Text('返回我的应用'),
        ),
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 14,
            runSpacing: 8,
            children: [
              Wrap(
                spacing: 4,
                children: [
                  choice(
                    '调用次数',
                    metric == _Metric.calls,
                    () => setState(() => metric = _Metric.calls),
                  ),
                  choice(
                    '到期未用',
                    metric == _Metric.expiry,
                    () => setState(() => metric = _Metric.expiry),
                  ),
                ],
              ),
              Wrap(
                spacing: 4,
                children: [
                  choice('近 7 天', date == null, () => select(null)),
                  choice('今天', date == usage.today, () => select(usage.today)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            date == null
                ? '${_dateText(dates.first)}至${_dateText(dates.last)} · 按天'
                : '${_dateText(date)} · 按小时',
            style: context.theme.typography.body.sm.copyWith(
              color: context.theme.colors.mutedForeground,
            ),
          ),
          const SizedBox(height: 8),
          if (metric == _Metric.calls)
            _CallHistory(usage, date, select)
          else
            _ExpiryHistory(
              _expired(widget.accounts, usage),
              dates,
              date,
              select,
            ),
        ],
      );
    },
  );
}

class _ExpiryHistory extends StatelessWidget {
  const _ExpiryHistory(this.records, this.dates, this.date, this.select);
  final List<AccountExpiryRecord> records;
  final List<DateTime> dates;
  final DateTime? date;
  final ValueChanged<DateTime> select;
  @override
  Widget build(BuildContext context) {
    final rows = records
        .where((r) => date == null || usageDate(r.batch.at) == date)
        .toList();
    final pending = rows.where((r) => r.batch.unused == null).length;
    if (rows.isEmpty) return const Text('这个时段暂无可核实的到期记录。');
    final totals = _amounts(rows);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (totals.isNotEmpty)
          Wrap(
            spacing: 24,
            runSpacing: 6,
            children: [
              for (final e in totals.entries)
                Text(
                  '${_provider(e.key.$1)}  ${_quantity(e.value)} ${e.key.$2}',
                  style: context.theme.typography.display.sm,
                ),
            ],
          ),
        if (pending > 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('$pending 批额度待核实，未计入已确认数量。'),
          ),
        if (date == null)
          for (final d in dates)
            FTile(
              title: Text(_dateText(d)),
              subtitle: Text(
                _quantities(rows.where((r) => usageDate(r.batch.at) == d)),
              ),
              suffix: const Icon(FLucideIcons.chevronRight, size: 14),
              onPress: () => select(d),
            )
        else
          for (final group in _byHour(rows).entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Text(
                group.key == null ? '仅有日期，时刻未知' : accountTime(group.key!),
                style: context.theme.typography.body.md.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (group.value.length > 1) Text(_quantities(group.value)),
            for (final row in group.value)
              FTile(
                title: Text('${_provider(row.provider)} · ${row.account}'),
                subtitle: Text(
                  row.batch.unused == null
                      ? '待核实'
                      : '${_quantity(row.batch.unused!)} ${row.batch.unit}',
                ),
              ),
          ],
      ],
    );
  }

  static String _quantities(Iterable<AccountExpiryRecord> rows) {
    if (rows.isEmpty) return '暂无记录';
    final pending = rows.where((r) => r.batch.unused == null).length;
    return [
      for (final e in _amounts(rows).entries)
        '${_provider(e.key.$1)} ${_quantity(e.value)} ${e.key.$2}',
      if (pending > 0) '$pending 批待核实',
    ].join(' · ');
  }

  static Map<DateTime?, List<AccountExpiryRecord>> _byHour(
    List<AccountExpiryRecord> rows,
  ) {
    final result = <DateTime?, List<AccountExpiryRecord>>{};
    for (final row in rows) {
      final at = row.batch.at.toLocal();
      // Truncate elapsed minutes to keep repeated local hours distinct.
      final hour = at.subtract(
        Duration(
          minutes: at.minute,
          seconds: at.second,
          milliseconds: at.millisecond,
          microseconds: at.microsecond,
        ),
      );
      result.putIfAbsent(row.batch.dateOnly ? null : hour, () => []).add(row);
    }
    return result;
  }
}
