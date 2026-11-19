import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'plugin_rewards.dart';

class RewardBatchAction extends StatelessWidget {
  const RewardBatchAction({super.key, required this.rewards, this.onStarted});
  final PluginRewards rewards;
  final VoidCallback? onStarted;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([rewards.accounts, rewards.batch]),
    builder: (context, _) {
      final batch = rewards.batch.value;
      final running = batch != null && batch.checked < batch.total;
      final count = rewards.candidates.length;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FButton(
            key: const ValueKey('reward-batch-action'),
            prefix: const Icon(FLucideIcons.calendarCheck, size: 16),
            mainAxisSize: MainAxisSize.min,
            onPress: running || count == 0
                ? null
                : () {
                    rewards.claimAll();
                    onStarted?.call();
                  },
            child: Text(
              running ? '正在核对 ${batch.checked}/${batch.total}' : '辅助签到（$count）',
            ),
          ),
          const SizedBox(height: 6),
          Text(
            batch != null && !running
                ? [
                    '已检查 ${batch.checked} 个账号',
                    if (batch.failures.isNotEmpty)
                      '检查未完成：${batch.failures.join('、')}',
                    if (batch.balanceUnavailable) '额度尚未更新',
                  ].join(' · ')
                : '点击后逐个核对账号，辅助领取本轮开放的奖励。',
            style: context.theme.typography.body.xs.copyWith(
              color: context.theme.colors.mutedForeground,
            ),
          ),
        ],
      );
    },
  );
}
