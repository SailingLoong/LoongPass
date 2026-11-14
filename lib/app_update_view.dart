import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'app_updates.dart';

String _status(UpdatePhase phase) => switch (phase) {
  UpdatePhase.idle => '将在后台检查并准备更新',
  UpdatePhase.checking => '正在检查更新',
  UpdatePhase.downloading => '正在后台下载更新',
  UpdatePhase.preparing => '正在校验并准备更新',
  UpdatePhase.ready => '更新已准备好，可重启并更新',
  UpdatePhase.installing => '正在安装更新',
  UpdatePhase.upToDate => '当前已是最新版本',
  UpdatePhase.error => '更新未完成，可稍后重试',
};

class AppUpdateCard extends StatelessWidget {
  const AppUpdateCard({super.key, required this.updates});
  final AppUpdates updates;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: updates,
    builder: (context, _) {
      final theme = context.theme;
      final version = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '应用更新',
            style: theme.typography.body.sm.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            updates.version == null ? '正在读取版本信息' : '当前版本 ${updates.version}',
            style: theme.typography.body.xs.copyWith(
              color: theme.colors.mutedForeground,
            ),
          ),
          if (updates.offeredVersion != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('可用版本 ${updates.offeredVersion}'),
            ),
        ],
      );
      final actions = Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (updates.phase == UpdatePhase.ready)
            FButton(
              size: FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              onPress: updates.canInstall ? updates.install : null,
              prefix: const Icon(FLucideIcons.refreshCw, size: 17),
              child: const Text('重启并更新'),
            )
          else
            FButton(
              variant: FButtonVariant.outline,
              size: FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              onPress: updates.available && updates.canCheck
                  ? updates.check
                  : null,
              prefix: const Icon(FLucideIcons.download, size: 17),
              child: const Text('检查更新'),
            ),
          if (updates.canSkip)
            FButton(
              variant: FButtonVariant.ghost,
              size: FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              onPress: updates.skip,
              child: const Text('放弃本次更新'),
            ),
        ],
      );
      return DefaultTextStyle(
        style: theme.typography.body.sm,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) =>
                  constraints.maxWidth >=
                      520 * MediaQuery.textScalerOf(context).scale(14) / 14
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: version),
                        const SizedBox(width: 16),
                        actions,
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [version, const SizedBox(height: 10), actions],
                    ),
            ),
            const SizedBox(height: 10),
            Semantics(
              liveRegion: true,
              child: Text(
                updates.phase == UpdatePhase.idle && !updates.automaticUpdates
                    ? '自动检查已关闭，可手动检查更新'
                    : _status(updates.phase),
              ),
            ),
            if (updates.phase == UpdatePhase.downloading ||
                updates.phase == UpdatePhase.preparing) ...[
              const SizedBox(height: 8),
              if (updates.progress case final progress?)
                FDeterminateProgress(value: progress)
              else
                const FProgress(),
            ],
            if (updates.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  updates.error!,
                  style: TextStyle(color: theme.colors.error),
                ),
              ),
            const FDivider(),
            FSwitch(
              value: updates.automaticUpdates,
              label: const Text('自动检查并预下载更新'),
              description: Text(
                updates.installOnQuit
                    ? '后台下载并校验，准备好后可重启更新，或在退出时安装。'
                    : '后台下载并校验，准备好后手动安装。',
              ),
              leadingLabel: true,
              enabled: updates.available,
              onChange: updates.setAutomaticUpdates,
            ),
            const SizedBox(height: 12),
            FSwitch(
              value: updates.receiveBetaUpdates,
              label: const Text('接收 Beta 版更新'),
              description: Text(
                updates.available && !updates.canChangeChannel
                    ? '更新进行中或已下载，安装或放弃后可切换渠道。'
                    : '提前体验新功能，可能存在不稳定情况。关闭后接收正式版。',
              ),
              leadingLabel: true,
              enabled: updates.available && updates.canChangeChannel,
              onChange: updates.setReceiveBetaUpdates,
            ),
          ],
        ),
      );
    },
  );
}

/// The same passive state is visible away from settings, including narrow mode.
class AppUpdateBadge extends StatelessWidget {
  const AppUpdateBadge({
    super.key,
    required this.updates,
    required this.compact,
    required this.onOpen,
  });
  final AppUpdates updates;
  final bool compact;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: updates,
    builder: (context, _) {
      if (updates.phase == UpdatePhase.idle ||
          updates.phase == UpdatePhase.upToDate)
        return const SizedBox.shrink();
      final ready = updates.phase == UpdatePhase.ready;
      final label = ready ? '重启并更新' : _status(updates.phase);
      final icon = Icon(
        ready ? FLucideIcons.refreshCw : FLucideIcons.download,
        size: 17,
      );
      return Padding(
        padding: const EdgeInsets.all(8),
        child: FTooltip(
          tipBuilder: (context, controller) => Text(label),
          child: FButton(
            variant: ready ? FButtonVariant.primary : FButtonVariant.ghost,
            size: FButtonSizeVariant.sm,
            semanticsLabel: label,
            onPress: ready
                ? (updates.canInstall ? updates.install : null)
                : onOpen,
            prefix: compact ? null : icon,
            child: compact
                ? icon
                : Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
          ),
        ),
      );
    },
  );
}
