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
      return FButton(
        key: const ValueKey('reward-batch-action'),
        size: FButtonSizeVariant.sm,
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
      );
    },
  );
}

class RewardBatchStatus extends StatelessWidget {
  const RewardBatchStatus({super.key, required this.rewards});
  final PluginRewards rewards;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: rewards.batch,
    builder: (context, batch, _) {
      if (batch == null || batch.checked < batch.total)
        return const SizedBox.shrink();
      return Semantics(
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            [
              '已检查 ${batch.checked} 个账号',
              if (batch.failures.isNotEmpty)
                '检查未完成：${batch.failures.join('、')}',
              if (batch.balanceUnavailable) '额度尚未更新',
            ].join(' · '),
            style: context.theme.typography.body.sm,
          ),
        ),
      );
    },
  );
}
