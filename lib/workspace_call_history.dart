part of 'workspace_usage.dart';

class _CallHistory extends StatelessWidget {
  const _CallHistory(this.usage, this.date, this.select);
  final MagpieUsage usage;
  final DateTime? date;
  final ValueChanged<DateTime> select;
  @override
  Widget build(BuildContext context) {
    final dates = date == null ? usage.dates : [date!];
    final known = dates.map(usage.day).whereType<UsageDay>().toList();
    final complete = known.length == dates.length;
    final failedRead = dates.any(usage.unavailable);
    final counts = known.fold(0, (n, d) => n + d.totals.calls);
    final failed = known.fold(0, (n, d) => n + d.totals.failed);
    final latest = known.isEmpty
        ? null
        : (known.map((d) => d.checkedAt).toList()..sort()).last;
    final input = known.fold(0, (n, d) => n + d.totals.input),
        output = known.fold(0, (n, d) => n + d.totals.output);
    final small = context.theme.typography.body.sm.copyWith(
      color: context.theme.colors.mutedForeground,
    );
    final day = date == null ? null : usage.day(date!);
    final peak = known.fold(
      1,
      (n, d) => d.totals.calls > n ? d.totals.calls : n,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (complete)
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('$counts 次', style: context.theme.typography.display.lg),
              Text('其中 $failed 次最终失败', style: small),
            ],
          ),
        Text('本机 Magpie 路由到 LoongPass 的请求', style: small),
        if (failedRead)
          Text(
            known.isEmpty ? '调用记录暂不可用，请检查本机 Magpie 是否运行。' : '部分时段未能更新，已保留上次记录。',
            style: small,
          )
        else if (!complete)
          Text('正在读取调用记录…', style: small),
        if (latest != null)
          Text(
            '最近读取 ${_dateText(latest)} ${accountTime(latest)}',
            style: small,
          ),
        const SizedBox(height: 12),
        if (date == null)
          for (final d in dates)
            FTile(
              title: Text(_dateText(d)),
              subtitle: usage.day(d) == null
                  ? null
                  : _UsageBar(usage.day(d)!.totals.calls / peak),
              suffix: Text(
                usage.day(d) == null ? '—' : '${usage.day(d)!.totals.calls} 次',
              ),
              onPress: () => select(d),
            ),
        if (day != null) _HourlyCalls(day),
        if (complete && (input > 0 || output > 0))
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              '已记录输入 $input tokens · 输出 $output tokens',
              style: small,
            ),
          ),
        if (day != null && day.recent.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('最近调用', style: context.theme.typography.display.sm),
          for (final call in day.recent)
            FTile(
              title: Text(call.model),
              subtitle: Text(
                [
                  accountTime(call.at),
                  if (call.account.isNotEmpty) call.account,
                  if (call.canceled) '已取消' else if (call.failed) '最终失败',
                ].join(' · '),
              ),
            ),
        ],
      ],
    );
  }
}

class _UsageBar extends StatelessWidget {
  const _UsageBar(this.fraction);
  final double fraction;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: FractionallySizedBox(
      widthFactor: fraction,
      child: Container(
        height: 4,
        decoration: BoxDecoration(
          color: context.desktopPalette.brand,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    ),
  );
}

class _HourlyCalls extends StatelessWidget {
  const _HourlyCalls(this.day);
  final UsageDay day;
  @override
  Widget build(BuildContext context) {
    final hours = day.hours.where((h) => !h.at.isAfter(day.checkedAt)).toList();
    final peak = hours.fold(
      1,
      (n, h) => h.totals.calls > n ? h.totals.calls : n,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('每小时调用次数', style: context.theme.typography.body.sm),
        const SizedBox(height: 8),
        SizedBox(
          height: 74,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final h in day.hours)
                Expanded(
                  child: FTooltip(
                    tipBuilder: (context, controller) => Text(
                      '${accountTime(h.at)} · ${h.at.isAfter(day.checkedAt) ? '尚未到时' : '${h.totals.calls} 次'}',
                    ),
                    child: Semantics(
                      label:
                          '${accountTime(h.at)}，${h.at.isAfter(day.checkedAt) ? '尚未到时' : '${h.totals.calls} 次'}',
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1),
                        child: Container(
                          height: h.at.isAfter(day.checkedAt)
                              ? 1
                              : (h.totals.calls == 0
                                    ? 1
                                    : 72 * h.totals.calls / peak),
                          color:
                              h.at.isAfter(day.checkedAt) || h.totals.calls == 0
                              ? context.theme.colors.border
                              : context.desktopPalette.brand,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final i in [
              0,
              day.hours.length ~/ 4,
              day.hours.length ~/ 2,
              3 * day.hours.length ~/ 4,
              day.hours.length - 1,
            ])
              Text(
                '${day.hours[i].at.hour} 时',
                style: context.theme.typography.body.xs,
              ),
          ],
        ),
        FAccordion(
          children: [
            FAccordionItem(
              title: const Text('逐小时数字'),
              child: Wrap(
                spacing: 16,
                runSpacing: 6,
                children: [
                  for (final h in hours)
                    Text('${accountTime(h.at)}  ${h.totals.calls} 次'),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
