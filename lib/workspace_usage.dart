import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'account_table_entry.dart';
import 'credit_expiry_history.dart';
import 'credit_timeline.dart';
import 'account_workspace_registry.dart';
import 'select_field_semantics.dart';
import 'desktop_theme.dart';
import 'magpie_usage.dart';
import 'managed_app.dart';
import 'plugin_accounts.dart';
import 'workspace_page.dart';

part 'workspace_call_history.dart';
part 'workspace_credit_plot.dart';
part 'workspace_credit_ranking.dart';

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
    this.registry,
  });
  final MagpieUsage usage;
  final PluginAccounts accounts;
  final AccountWorkspaceRegistry? registry;
  void _open(BuildContext context, _Metric metric) => openCreditTimeline(
    context,
    usage,
    accounts,
    hourly: metric == _Metric.calls,
    registry: registry,
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

String _unit(String unit) => switch (unit) {
  'credits' => '积分',
  '' => '单位未知',
  _ => unit,
};
String _when(CreditExpiryEvidence b) =>
    '${_dateText(b.at)} ${b.dateOnly ? '仅知日期' : accountTime(b.at)}';
String _bucketLabel(TimelineBucket b, CreditSource? source, bool debit) {
  final unit = source == null ? '批' : _unit(source.unit);
  return [
    if (b.usage != null)
      '${_quantity(b.usage!)} ${debit ? unit : '次调用'}'
    else if (!b.start.isAfter(b.now))
      debit ? '该时段账单不完整' : '调用记录暂缺',
    if (b.loss > 0) '确认未用 ${_quantity(b.loss)} $unit',
    if (b.forecast > 0) '将到期 ${_quantity(b.forecast)} $unit',
    if (b.unknown > 0) '${b.unknown} 批余量未知',
    if (b.rows.isEmpty) '无已知到期批次',
    if (b.rows.isNotEmpty && b.loss == 0 && b.forecast == 0 && b.unknown == 0)
      '已核实用完',
  ].join(' · ');
}

void openCreditTimeline(
  BuildContext context,
  MagpieUsage usage,
  PluginAccounts accounts, {
  DateTime? day,
  bool hourly = false,
  AccountWorkspaceRegistry? registry,
}) => Navigator.of(context).push<void>(
  PageRouteBuilder<void>(
    settings: const RouteSettings(name: '/overview/usage'),
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    pageBuilder: (context, _, _) => ColoredBox(
      color: context.theme.colors.background,
      child: _UsagePage(usage, accounts, day, hourly, registry),
    ),
  ),
);

class _UsagePage extends StatefulWidget {
  const _UsagePage(
    this.usage,
    this.accounts,
    this.date,
    this.hourly,
    this.registry,
  );
  final MagpieUsage usage;
  final PluginAccounts accounts;
  final DateTime? date;
  final bool hourly;
  final AccountWorkspaceRegistry? registry;
  @override
  State<_UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<_UsagePage> {
  late var center = widget.date ?? widget.usage.today;
  late var selected = widget.date ?? widget.usage.now;
  late var hourly = widget.hourly;
  CreditSource? source;
  bool debit = false, details = false;
  final scroll = ScrollController();
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  void focus(DateTime at, {bool? hours, bool show = false}) {
    center = usageDate(at);
    selected = at;
    hourly = hours ?? hourly;
    details = show;
  }

  void jumpToChart() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (scroll.hasClients)
      scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
  });
  Widget choice(String label, bool active, VoidCallback click) => FButton(
    variant: active ? FButtonVariant.primary : FButtonVariant.outline,
    size: FButtonSizeVariant.sm,
    mainAxisSize: MainAxisSize.min,
    onPress: click,
    child: Text(label),
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.usage,
      widget.accounts,
      widget.registry,
    ]),
    builder: (context, _) {
      final usage = widget.usage,
          data = CreditTimeline(widget.accounts, usage.now);
      final sources = data.sources.toList()
        ..sort(
          (a, b) => ('${_provider(a.provider)} ${a.unit}').compareTo(
            '${_provider(b.provider)} ${b.unit}',
          ),
        );
      final active = sources.contains(source) ? source : null,
          billed = data.bills(active) && debit;
      final buckets = creditTimelineBuckets(
        data,
        usage,
        center,
        hourly: hourly,
        source: active,
        debit: billed,
      );
      final bucket =
          buckets
              .where(
                (b) => !selected.isBefore(b.start) && selected.isBefore(b.end),
              )
              .firstOrNull ??
          buckets.first;
      final dateOnly = data.records
          .where(
            (r) =>
                r.batch.dateOnly &&
                usageDate(r.batch.at) == usageDate(selected) &&
                (active == null || creditSource(r) == active),
          )
          .toList();
      final bySource = data.future
          .where((r) => active == null || creditSource(r) == active)
          .toList();
      final small = context.theme.typography.body.xs.copyWith(
        color: context.theme.colors.mutedForeground,
      );
      void selectSource(CreditSource? s) {
        setState(() {
          source = s;
          debit = false;
        });
      }

      void step(int i) {
        final at = hourly
            ? bucket.start.add(Duration(hours: i))
            : DateTime(
                bucket.start.year,
                bucket.start.month,
                bucket.start.day + i,
              );
        setState(() {
          selected = at;
          if (at.isBefore(buckets.first.start) ||
              !at.isBefore(buckets.last.end))
            center = usageDate(at);
        });
      }

      return WorkspacePage(
        title: '用量与到期',
        controller: scroll,
        action: FButton(
          variant: FButtonVariant.ghost,
          size: FButtonSizeVariant.sm,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(),
          child: const Text('返回我的应用'),
        ),
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Wrap(
                spacing: 3,
                children: [
                  choice(
                    '按天',
                    !hourly,
                    () => setState(() => focus(selected, hours: false)),
                  ),
                  choice(
                    '按小时',
                    hourly,
                    () => setState(() => focus(selected, hours: true)),
                  ),
                ],
              ),
              SizedBox(
                width: 152,
                child: FDateField.calendar(
                  size: FTextFieldSizeVariant.sm,
                  clearable: false,
                  format: (_, value, _) =>
                      '${value.year}/${value.month}/${value.day}',
                  selectionControl: FDateSelectionControl.liftedSingle(
                    value: DateTime.utc(
                      selected.year,
                      selected.month,
                      selected.day,
                    ),
                    toggleable: false,
                    onChange: (v) {
                      if (v != null)
                        setState(() => focus(DateTime(v.year, v.month, v.day)));
                    },
                  ),
                ),
              ),
              SizedBox(
                width: 190,
                child: FSelect<int>(
                  builder: selectFieldSemantics,
                  size: FTextFieldSizeVariant.sm,
                  items: {
                    '全部来源 · 批次': -1,
                    for (var i = 0; i < sources.length; i++)
                      '${_provider(sources[i].provider)} · ${_unit(sources[i].unit)}':
                          i,
                  },
                  control: FSelectControl.lifted(
                    value: active == null ? -1 : sources.indexOf(active),
                    onChange: (i) {
                      if (i != null) selectSource(i < 0 ? null : sources[i]);
                    },
                  ),
                ),
              ),
              if (data.bills(active))
                Wrap(
                  spacing: 3,
                  children: [
                    choice(
                      '本机调用',
                      !billed,
                      () => setState(() => debit = false),
                    ),
                    choice('积分消耗', billed, () => setState(() => debit = true)),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 16),
          _TimelinePlot(
            buckets,
            selected,
            (b) => setState(() => selected = b.start),
            hourly: hourly,
            source: active,
            debit: billed,
          ),
          if (hourly && dateOnly.isNotEmpty) ...[
            const SizedBox(height: 8),
            FAccordion(
              children: [
                FAccordionItem(
                  title: Text('当天仅知日期 · ${dateOnly.length} 批'),
                  child: Column(
                    children: [for (final r in dateOnly) _entry(data, r)],
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 6,
            spacing: 12,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_dateText(bucket.start)} ${hourly ? accountTime(bucket.start) : '全天'}',
                    style: context.theme.typography.body.md.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(_bucketLabel(bucket, active, billed), style: small),
                ],
              ),
              Wrap(
                spacing: 4,
                children: [
                  _stepButton('上一时段', FLucideIcons.chevronLeft, () => step(-1)),
                  choice(
                    details ? '收起明细' : '查看明细',
                    false,
                    () => setState(() => details = !details),
                  ),
                  _stepButton('下一时段', FLucideIcons.chevronRight, () => step(1)),
                ],
              ),
            ],
          ),
          if (details) ...[
            for (final r in bucket.rows) _entry(data, r),
            if (!hourly)
              Align(
                alignment: Alignment.centerLeft,
                child: FButton(
                  variant: FButtonVariant.ghost,
                  size: FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => setState(
                    () => focus(bucket.start, hours: true, show: true),
                  ),
                  child: const Text('查看这天的小时明细'),
                ),
              ),
          ],
          const SizedBox(height: 24),
          _SourceRanking(
            data,
            onSource: (s) {
              selectSource(s);
              jumpToChart();
            },
            entry: (r) => _entry(data, r),
          ),
          const SizedBox(height: 14),
          FAccordion(
            children: [
              FAccordionItem(
                title: Text(
                  bySource.isEmpty
                      ? '接下来到期 · 暂无已知批次'
                      : '接下来到期 · ${_when(bySource.first.batch)} · ${_provider(bySource.first.provider)}',
                ),
                child: Column(
                  children: [
                    for (final r in bySource)
                      _entry(
                        data,
                        r,
                        onPress: () {
                          setState(() {
                            source = creditSource(r);
                            debit = false;
                            focus(
                              r.batch.at,
                              hours: !r.batch.dateOnly,
                              show: true,
                            );
                          });
                          jumpToChart();
                        },
                      ),
                  ],
                ),
              ),
              if (!hourly || usage.dates.contains(usageDate(selected)))
                FAccordionItem(
                  title: const Text('本机调用明细'),
                  child: _CallHistory(
                    usage,
                    hourly ? usageDate(selected) : null,
                    (d) {
                      setState(() => focus(d, hours: true));
                      jumpToChart();
                    },
                  ),
                ),
            ],
          ),
        ],
      );
    },
  );
  Widget _stepButton(String label, IconData icon, VoidCallback onPress) =>
      FButton.icon(
        variant: FButtonVariant.ghost,
        size: FButtonSizeVariant.sm,
        onPress: onPress,
        child: Icon(icon, semanticLabel: label),
      );
  Widget _entry(
    CreditTimeline data,
    AccountExpiryRecord row, {
    VoidCallback? onPress,
  }) {
    final b = row.batch, future = b.end.isAfter(data.now), unit = _unit(b.unit);
    final amount = b.remaining == null
        ? null
        : '${_quantity(b.remaining!)} $unit';
    final observed = b.observedAt;
    final app = ManagedApp.values
        .where((a) => a.nativeProviders.contains(row.provider))
        .firstOrNull;
    final key = data.accountKeys[row];
    final account = app == null || key == null
        ? null
        : widget.registry
              ?.entriesFor(app)
              .where((r) => r.id == key)
              .firstOrNull;
    final models =
        account?.expiryModels[(
          at: b.at,
          amount: b.remaining == null
              ? null
              : '${accountPoints(b.remaining!)} ${b.unit}',
        )];
    return FTile(
      title: Text('${_provider(row.provider)} · ${row.account}'),
      subtitle: Text(
        [
          _when(b),
          if (future)
            amount == null ? '平台未提供批次余量' : '将到期 $amount'
          else if (b.unused != null)
            '已确认未用 ${_quantity(b.unused!)} $unit'
          else
            '平台未提供可核对的到期结算',
          if (!future && b.unused == null && amount != null) '到期前余量 $amount',
          if (observed != null && (future || b.unused == null))
            '查询于 ${_dateText(observed)} ${accountTime(observed)}',
          if (future && models != null && models.isNotEmpty)
            '可用模型 ${models.join('、')}',
        ].join(' · '),
      ),
      suffix: onPress == null
          ? null
          : const Icon(FLucideIcons.chevronRight, size: 14),
      onPress: onPress,
    );
  }
}
