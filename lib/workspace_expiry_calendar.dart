part of 'workspace_accounts.dart';

class _ExpiryCalendar extends StatefulWidget {
  const _ExpiryCalendar({
    required this.accounts,
    required this.registry,
    this.onTimeline,
  });
  final ValueChanged<DateTime>? onTimeline;
  final List<WorkspaceAccount> accounts;
  final AccountWorkspaceRegistry registry;
  @override
  State<_ExpiryCalendar> createState() => _ExpiryCalendarState();
}

class _ExpiryCalendarState extends State<_ExpiryCalendar> {
  DateTime? selection;
  @override
  Widget build(BuildContext context) {
    final week = WorkspaceExpiryWeek(widget.accounts, DateTime.now());
    final day = week.days.contains(selection) ? selection! : week.days.first;
    final batches = week.on(day);
    final colors = context.theme.colors;
    final palette = context.desktopPalette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '额度到期日程',
                style: context.theme.typography.display.lg.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (widget.onTimeline != null)
              FButton(
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                onPress: () => widget.onTimeline!(day),
                child: const Text('查看时间图'),
              ),
            Text(
              '未来 7 天',
              style: context.theme.typography.body.xs.copyWith(
                color: colors.mutedForeground,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: palette.sidebar,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              for (final (index, date) in week.days.indexed)
                Expanded(
                  child: FTappable(
                    key: Key('expiry-day-$index'),
                    selected: date == day,
                    semanticsLabel:
                        '${accountDate(date)}，${week.on(date).length} 批到期',
                    excludeSemantics: true,
                    semanticsInMutuallyExclusiveGroup: true,
                    onPress: () => setState(() => selection = date),
                    builder: (context, states, _) {
                      final selected = date == day;
                      final color = selected
                          ? palette.brandForeground
                          : colors.foreground;
                      final pips = week.on(date).length.clamp(0, 3);
                      return Container(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          color: selected
                              ? palette.brand
                              : states.contains(WidgetState.hovered)
                              ? palette.selected
                              : null,
                        ),
                        child: Column(
                          children: [
                            Text(
                              index == 0
                                  ? '今天'
                                  : '周${'一二三四五六日'[date.weekday - 1]}',
                              style: context.theme.typography.body.xs.copyWith(
                                color: color,
                              ),
                            ),
                            Text(
                              '${date.day}',
                              style: context.theme.typography.display.lg
                                  .copyWith(
                                    color: color,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            SizedBox(
                              height: 5,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  for (var i = 0; i < pips; i++)
                                    Container(
                                      width: 3,
                                      height: 3,
                                      margin: const EdgeInsets.symmetric(
                                        horizontal: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: color,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '${day.month} 月 ${day.day} 日 · ${batches.isEmpty ? '没有已知到期批次' : '${batches.length} 批已知到期额度'}',
          style: context.theme.typography.body.xs.copyWith(
            color: colors.mutedForeground,
          ),
        ),
        for (final batch in batches)
          _AccountLine(
            batch.account,
            widget.registry,
            batchAt: batch.at,
            status: batch.dateOnly
                ? '当天到期 · 仅知日期'
                : '${accountTime(batch.at)} 到期',
            amount: batch.amount,
          ),
      ],
    );
  }
}
