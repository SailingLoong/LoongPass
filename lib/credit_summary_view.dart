import 'package:flutter/material.dart';
import 'credit_summary.dart';
import 'account_table_entry.dart' show accountPoints;

/// Display only: refreshing a snapshot belongs to its account owner.
class CreditSummaryView extends StatelessWidget {
  const CreditSummaryView({super.key, required this.summary});
  final CreditSummary summary;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (summary.totalRemaining case final double total)
        Text('当前剩余：${accountPoints(total)} 积分'),
      if (summary.expiring.isNotEmpty) ...[
        Text(
          '最近到期：${creditTime(summary.expiring.first.expiresAt)} · ${accountPoints(summary.expiring.first.remaining)} 积分',
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('积分到期明细'),
          children: [
            for (final batch in summary.expiring)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '${creditTime(batch.expiresAt)} · ${accountPoints(batch.remaining)} 积分',
                ),
              ),
          ],
        ),
      ] else
        const Text('未查到有明确到期时间的剩余积分。'),
      if (summary.withoutExpiry > 0)
        Text('另有 ${accountPoints(summary.withoutExpiry)} 积分未提供到期时间。'),
      Text(
        '更新于 ${creditTime(summary.observedAt)}；剩余额度会随使用变化。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );
}

String creditTime(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final offset = local.timeZoneOffset;
  final zone =
      '${offset.isNegative ? '-' : '+'}${two(offset.inHours.abs())}:${two(offset.inMinutes.abs() % 60)}';
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)} UTC$zone';
}
