import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'account_table_entry.dart';
import 'credit_summary_view.dart';

/// All entry points observe the same live presentation; opening never refreshes.
Future<void> showAccountDetails(
  BuildContext context, {
  required Listenable listenable,
  required AccountTableEntry? Function() read,
  bool expiry = false,
}) async {
  read()?.onOpenDetails?.call();
  var showExpiry = expiry;
  await showFDialog<void>(
    context: context,
    builder: (context, style, animation) => StatefulBuilder(
      builder: (context, setState) => ListenableBuilder(
        listenable: listenable,
        builder: (context, _) {
          final row = read();
          return FDialog(
            animation: animation,
            constraints: const BoxConstraints(minWidth: 280, maxWidth: 640),
            builder: (context, style) => Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    row == null
                        ? '账号已移除'
                        : showExpiry
                        ? '额度到期'
                        : row.label,
                    style: context.theme.typography.display.xl.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (row != null &&
                      (showExpiry || row.sourceLabel != null)) ...[
                    const SizedBox(height: 4),
                    Text(
                      showExpiry ? row.label : row.sourceLabel!,
                      style: context.theme.typography.body.xs.copyWith(
                        color: context.theme.colors.mutedForeground,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Flexible(
                    child: SizedBox(
                      width: 592,
                      child: SingleChildScrollView(
                        child: DefaultTextStyle(
                          style: context.theme.typography.body.sm,
                          child: row == null
                              ? const Text('该账号已不在当前列表中。')
                              : showExpiry
                              ? _ExpiryDetails(row: row)
                              : Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (row.notice != null)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 12,
                                        ),
                                        child: Text(row.notice!),
                                      ),
                                    row.details,
                                    if (row.hasRewards) ...[
                                      const FDivider(),
                                      Text(
                                        '最近一次成功领取',
                                        style: context.theme.typography.body.sm
                                            .copyWith(
                                              fontWeight: FontWeight.w500,
                                            ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(row.latestClaim),
                                    ],
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    children: [
                      if (showExpiry && row != null)
                        FButton(
                          variant: FButtonVariant.outline,
                          size: FButtonSizeVariant.sm,
                          mainAxisSize: MainAxisSize.min,
                          onPress: () => setState(() => showExpiry = false),
                          child: const Text('查看账号详情'),
                        ),
                      FButton(
                        variant: FButtonVariant.ghost,
                        size: FButtonSizeVariant.sm,
                        mainAxisSize: MainAxisSize.min,
                        onPress: () => Navigator.pop(context),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _ExpiryDetails extends StatelessWidget {
  const _ExpiryDetails({required this.row});
  final AccountTableEntry row;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        row.upcomingExpiryAmount == '—' ? '到期额度未知' : row.upcomingExpiryAmount,
        style: context.theme.typography.display.xl.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 6),
      Text(
        row.nextExpiry == null ? '到期时间未知' : '${creditTime(row.nextExpiry!)} 到期',
      ),
      const SizedBox(height: 16),
      if (row.expiryDetails != null)
        row.expiryDetails!
      else if (row.credits case final credits?) ...[
        Text(
          '已知到期批次 · 当前剩余额度',
          style: context.theme.typography.body.sm.copyWith(
            fontWeight: FontWeight.w500,
          ),
        ),
        for (final batch in upcomingCreditBatches(credits))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              '${accountPoints(batch.remaining)} 积分 · ${creditTime(batch.expiresAt)} 到期',
            ),
          ),
        if (credits.withoutExpiry > 0)
          Text('另有 ${accountPoints(credits.withoutExpiry)} 积分到期时间未知。'),
      ] else
        const Text('此处为最近一批已知到期信息；平台未提供的明细仍为未知。'),
      const SizedBox(height: 12),
      Text(
        row.queriedAt == null ? '查询时间未知' : '查询于 ${creditTime(row.queriedAt!)}',
        style: context.theme.typography.body.xs.copyWith(
          color: context.theme.colors.mutedForeground,
        ),
      ),
    ],
  );
}
