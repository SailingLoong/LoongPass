import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'app_updates.dart';
import 'desktop_theme.dart';
import 'update_contract.dart';

String _percentage(AppUpdates updates) =>
    updates.progress == null ? '进度未知' : '${(updates.progress! * 100).floor()}%';

String _speed(AppUpdates updates) {
  final speed = updates.downloadBytesPerSecond;
  if (speed == null) return '计算速度…';
  if (speed >= 1048576) return '${(speed / 1048576).toStringAsFixed(1)} MiB/s';
  if (speed >= 1024) return '${(speed / 1024).toStringAsFixed(1)} KiB/s';
  return '${speed.round()} B/s';
}

String _checkTime(DateTime time) {
  String pair(int value) => value.toString().padLeft(2, '0');
  final local = time.toLocal();
  return '${pair(local.month)}-${pair(local.day)} ${pair(local.hour)}:${pair(local.minute)}';
}

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

Future<void> _confirmUpdate(
  BuildContext context,
  AppUpdates updates, {
  bool discard = false,
}) async {
  final version = updates.offeredVersion;
  final confirmed = await showFDialog<bool>(
    context: context,
    builder: (context, style, animation) => FDialog(
      animation: animation,
      constraints: const BoxConstraints(maxWidth: 448),
      builder: (context, style) => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(discard ? '放弃本次更新？' : '重启并更新？', style: style.titleTextStyle),
            const SizedBox(height: 12),
            Text(
              discard
                  ? '只放弃当前候选版本，后续检查仍按设置进行。'
                  : '请先保存正在进行的工作。LoongPass 将退出并安装已准备好的更新。',
              style: style.bodyTextStyle,
            ),
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FButton(
                    mainAxisSize: MainAxisSize.min,
                    variant: FButtonVariant.outline,
                    onPress: () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  FButton(
                    mainAxisSize: MainAxisSize.min,
                    onPress: () => Navigator.pop(context, true),
                    child: Text(discard ? '确认放弃' : '确认重启'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (confirmed != true ||
      !context.mounted ||
      updates.offeredVersion != version)
    return;
  if (discard) {
    if (updates.canSkip) await updates.skip();
  } else if (updates.canInstall) {
    await updates.install();
  }
}

class _TransferProgress extends StatelessWidget {
  const _TransferProgress(this.progress);
  final double? progress;
  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final track = DecorationDelta.boxDelta(
      color: colors.brightness == Brightness.dark
          ? const Color(0xff35373b)
          : const Color(0xffe5e5e5),
    );
    final fill = DecorationDelta.boxDelta(color: context.desktopPalette.brand);
    const size = BoxConstraints.tightFor(height: 4);
    return progress == null
        ? FProgress(
            style: FProgressStyleDelta.delta(
              constraints: size,
              trackDecoration: track,
              fillDecoration: fill,
            ),
          )
        : FDeterminateProgress(
            value: progress!,
            style: FDeterminateProgressStyleDelta.delta(
              constraints: size,
              trackDecoration: track,
              fillDecoration: fill,
            ),
          );
  }
}

class AppUpdateCard extends StatelessWidget {
  const AppUpdateCard({super.key, required this.updates});
  final AppUpdates updates;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: updates,
    builder: (context, _) {
      final theme = context.theme;
      final transfer =
          updates.phase == UpdatePhase.downloading ||
          updates.phase == UpdatePhase.preparing;
      final actions = Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (updates.phase == UpdatePhase.ready)
            FButton(
              size: FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              onPress: updates.canInstall
                  ? () => _confirmUpdate(context, updates)
                  : null,
              prefix: const Icon(FLucideIcons.refreshCw, size: 17),
              child: const Text('重启并更新'),
            )
          else if (!transfer &&
              updates.phase != UpdatePhase.installing &&
              updates.phase != UpdatePhase.checking)
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
              onPress: () => _confirmUpdate(context, updates, discard: true),
              child: const Text('放弃本次更新'),
            ),
        ],
      );
      return DefaultTextStyle(
        style: theme.typography.body.sm,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              children: [
                Text(
                  '版本与更新',
                  style: theme.typography.body.lg.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  updates.version == null
                      ? '正在读取版本信息'
                      : '当前版本 ${updates.version}',
                  style: theme.typography.body.xs.copyWith(
                    color: theme.colors.mutedForeground,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: context.desktopPalette.sidebar,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 6,
                    children: [
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          updates.phase == UpdatePhase.idle &&
                                  !updates.automaticUpdates
                              ? '自动检查已关闭，可手动检查更新'
                              : _status(updates.phase),
                          style: theme.typography.body.sm.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (actions.children.isNotEmpty) actions,
                    ],
                  ),
                  if (updates.offeredVersion != null)
                    Text(
                      '可用版本 ${updates.offeredVersion}',
                      style: theme.typography.body.xs,
                    ),
                  if (updates.phase == UpdatePhase.downloading)
                    Wrap(
                      spacing: 8,
                      children: [
                        Text(_percentage(updates)),
                        Text(_speed(updates)),
                      ],
                    ),
                  if (transfer) ...[
                    const SizedBox(height: 8),
                    _TransferProgress(updates.progress),
                  ],
                  if (updates.error != null)
                    Text(
                      updates.error!,
                      style: TextStyle(color: theme.colors.error),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            FSwitch(
              value: updates.automaticUpdates,
              label: const Text('自动检查并预下载更新'),
              description: Text(
                updates.installOnQuit
                    ? '每 ${UpdateContract.checkIntervalSeconds ~/ 3600} 小时检查并预下载，准备好后可重启更新，或在退出时安装。'
                    : '每 ${UpdateContract.checkIntervalSeconds ~/ 3600} 小时检查并预下载，准备好后手动安装。',
              ),
              leadingLabel: true,
              enabled: updates.available,
              onChange: updates.setAutomaticUpdates,
            ),
            const FDivider(),
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
            const FDivider(),
            _CheckFact(
              '上次检查',
              updates.lastCheckAt == null
                  ? '尚无记录'
                  : _checkTime(updates.lastCheckAt!),
            ),
            const FDivider(),
            _CheckFact(
              '下次检查',
              !updates.automaticUpdates
                  ? '已关闭'
                  : updates.nextCheckAt == null
                  ? '本次更新处理完成后继续'
                  : '约 ${_checkTime(updates.nextCheckAt!)}',
            ),
          ],
        ),
      );
    },
  );
}

class _CheckFact extends StatelessWidget {
  const _CheckFact(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.spaceBetween,
    spacing: 8,
    children: [
      Text(
        label,
        style: context.theme.typography.body.sm.copyWith(
          color: context.theme.colors.mutedForeground,
        ),
      ),
      Text(value),
    ],
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
      final status = ready ? '重启并更新' : _status(updates.phase);
      final telemetry = updates.phase == UpdatePhase.downloading
          ? '${_percentage(updates)} · ${_speed(updates)}'
          : null;
      final label = telemetry == null ? status : '$status · $telemetry';
      final icon = Icon(
        ready ? FLucideIcons.refreshCw : FLucideIcons.download,
        size: 17,
      );
      return Container(
        margin: compact
            ? const EdgeInsets.symmetric(horizontal: 8)
            : const EdgeInsets.fromLTRB(10, 4, 10, 8),
        padding: EdgeInsets.symmetric(vertical: compact ? 0 : 2),
        decoration: compact
            ? null
            : BoxDecoration(
                border: Border(
                  top: BorderSide(color: context.theme.colors.border),
                ),
              ),
        child: FTooltip(
          tipBuilder: (context, controller) => Text(label),
          child: LayoutBuilder(
            builder: (context, bounds) {
              final iconOnly = compact && bounds.maxWidth < 105;
              final downloading = updates.phase == UpdatePhase.downloading;
              final failed = updates.phase == UpdatePhase.error;
              final compactLabel = switch (updates.phase) {
                UpdatePhase.error => '更新失败',
                UpdatePhase.downloading =>
                  updates.progress == null ? '下载中' : _percentage(updates),
                _ => status,
              };
              return FButton(
                variant: ready ? FButtonVariant.primary : FButtonVariant.ghost,
                mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
                mainAxisAlignment: compact || ready
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                size: FButtonSizeVariant.sm,
                semanticsLabel: label,
                onPress: ready
                    ? (updates.canInstall
                          ? () => _confirmUpdate(context, updates)
                          : null)
                    : onOpen,
                prefix: !iconOnly && (compact || ready) ? icon : null,
                child: iconOnly
                    ? icon
                    : compact || (!downloading && !failed)
                    ? Flexible(
                        child: Text(
                          compact ? compactLabel : status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      )
                    : Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Wrap(
                              alignment: WrapAlignment.spaceBetween,
                              spacing: 4,
                              children: [
                                Text(failed ? '更新未完成' : '下载更新'),
                                if (failed)
                                  const Icon(FLucideIcons.circleAlert, size: 15)
                                else
                                  Text(_percentage(updates)),
                              ],
                            ),
                            const SizedBox(height: 5),
                            if (failed)
                              Text(
                                '查看原因',
                                style: context.theme.typography.body.xs,
                              )
                            else ...[
                              _TransferProgress(updates.progress),
                              const SizedBox(height: 4),
                              Text(
                                _speed(updates),
                                style: context.theme.typography.body.xs
                                    .copyWith(
                                      fontSize: 11.5,
                                      height: 1.55,
                                      fontWeight: FontWeight.w400,
                                      color:
                                          context.theme.colors.mutedForeground,
                                    ),
                              ),
                            ],
                          ],
                        ),
                      ),
              );
            },
          ),
        ),
      );
    },
  );
}
