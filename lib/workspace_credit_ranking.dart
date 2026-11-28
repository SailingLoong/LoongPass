part of 'workspace_usage.dart';

class _SourceRanking extends StatelessWidget {
  const _SourceRanking(
    this.data, {
    required this.onSource,
    required this.entry,
  });
  final CreditTimeline data;
  final ValueChanged<CreditSource> onSource;
  final Widget Function(AccountExpiryRecord) entry;
  @override
  Widget build(BuildContext context) {
    final small = context.theme.typography.body.xs.copyWith(
      color: context.theme.colors.mutedForeground,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('哪些来源到期未用', style: context.theme.typography.display.sm),
            Text('近 7 天 · 全部来源', style: small),
          ],
        ),
        const SizedBox(height: 8),
        if (data.ranking.isEmpty)
          Text('近 7 天没有已记录的到期批次。', style: small)
        else ...[
          FAccordion(
            children: [
              for (final group in data.ranking)
                FAccordionItem(
                  title: LayoutBuilder(
                    builder: (context, box) {
                      final source = group.source,
                          lost = group.settled.isEmpty
                              ? '待核实'
                              : '${_quantity(group.unused)} ${_unit(source.unit)}';
                      final rate = group.rate == null
                          ? '—'
                          : '${(group.rate! * 100).toStringAsFixed(2)}%';
                      final coverage =
                          '${group.settled.length} / ${group.rows.length} 批';
                      if (box.maxWidth < 540)
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_provider(source.provider)),
                            Text(
                              '确认未用 $lost · 未用率 $rate · 已核实 $coverage',
                              style: small,
                            ),
                          ],
                        );
                      return Row(
                        children: [
                          Expanded(child: Text(_provider(source.provider))),
                          Expanded(child: Text('确认未用  $lost')),
                          Expanded(child: Text('未用率  $rate')),
                          Expanded(child: Text('已核实  $coverage')),
                        ],
                      );
                    },
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FButton(
                          variant: FButtonVariant.ghost,
                          size: FButtonSizeVariant.sm,
                          mainAxisSize: MainAxisSize.min,
                          onPress: () => onSource(group.source),
                          child: Text(
                            '在时间图查看 ${_provider(group.source.provider)}',
                          ),
                        ),
                      ),
                      for (final r
                          in group.rows.toList()
                            ..sort((a, b) => b.batch.at.compareTo(a.batch.at)))
                        entry(r),
                    ],
                  ),
                ),
            ],
          ),
          Text('按未用率排列。未用率为已核实批次的未用总量除以同批次发放总量。', style: small),
        ],
      ],
    );
  }
}
