import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart' show SelectableText;

import 'model_connection.dart';
import 'workspace_tools.dart' show WorkspaceCard;

class ModelConnectionPanel extends StatefulWidget {
  const ModelConnectionPanel({
    super.key,
    required this.connection,
    this.enabled = true,
  });
  final ModelConnection connection;
  final bool enabled;
  @override
  State<ModelConnectionPanel> createState() => _ModelConnectionPanelState();
}

class _ModelConnectionPanelState extends State<ModelConnectionPanel> {
  bool _guideUnavailable = false;
  bool _guideExpanded = false;
  Future<void> _guide() async {
    try {
      await const MethodChannel('com.sailingloong.loongpass/files')
          .invokeMethod<void>('openExternalHTTPS', {
            'url': 'https://github.com/SailingLoong/LoongPass/blob/main/docs/dsh-multi-agent.md',
          });
      if (mounted) setState(() => _guideUnavailable = false);
    } catch (_) {
      if (mounted) setState(() => _guideUnavailable = true);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.connection,
    builder: (context, _) {
      final connection = widget.connection, result = connection.inspection;
      final count = connection.selectedAccounts;
      final titleStyle = context.theme.typography.body.sm.copyWith(
        fontWeight: FontWeight.w600,
      );
      final checked = connection.checkedAt;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WorkspaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Magpie 接入', style: titleStyle),
                const SizedBox(height: 8),
                Text(
                  count == 0
                      ? '先在下方选择可用账号，再开启本机模型服务。'
                      : '已选择 $count 个有效账号。连接后由 Magpie 管理模型分组、路由和恢复。',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FButton(
                      variant: FButtonVariant.primary,
                      size: FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: widget.enabled && connection.canConnect
                          ? connection.connect
                          : null,
                      prefix: const Icon(FLucideIcons.link),
                      child: const Text('连接 Magpie'),
                    ),
                    FButton(
                      variant: FButtonVariant.outline,
                      size: FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: widget.enabled && !connection.busy
                          ? connection.check
                          : null,
                      prefix: const Icon(FLucideIcons.circleCheck),
                      child: Text(
                        connection.busy
                            ? '正在检查…'
                            : checked == null
                            ? '检查连接'
                            : '重新检查',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (connection.error != null)
                  Text(switch (connection.error!) {
                    ModelConnectionFailure.notReady =>
                      '请先开启本机模型服务，并选择至少一个有效账号。',
                    ModelConnectionFailure.saveFailed =>
                      '授权保存未完成。请检查连接状态，确认 Magpie 可用后重试连接。',
                    ModelConnectionFailure.changed => '账号或服务状态已变化，请重新检查。',
                  }),
                if (result == null)
                  const Text('尚无当前检查结果。检查不会发送模型请求。')
                else if (!result.executableFound)
                  const Text('未找到 Magpie 命令。请安装官方 Magpie，并确认命令可用。')
                else ...[
                  Text(
                    result.gatewayReady == true
                        ? 'Magpie 网关可达。'
                        : 'Magpie 网关不可达。请启动 Magpie，并检查其网关设置。',
                  ),
                  const SizedBox(height: 6),
                  Text(
                    connection.savedAccounts == null
                        ? '授权记录未确认。请在 Magpie 检查 LoongPass 插件状态；必要时更新 Magpie 后重试。'
                        : count == 0
                        ? '尚未选择账号。选择后连接 Magpie，再检查授权记录。'
                        : '授权记录：${connection.savedAccounts} / $count 个所选账号已保存。${connection.savedAccounts == count ? '' : '请重新连接 Magpie 同步授权。'}',
                  ),
                ],
                if (checked != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    '检查于 ${checked.toLocal().toString().substring(0, 19)} · 模型调用尚需在客户端验证。',
                    style: context.theme.typography.body.xs.copyWith(
                      color: context.theme.colors.mutedForeground,
                    ),
                  ),
                ],
              ],
            ),
          ),
          WorkspaceCard(
            child: FAccordion(
              control: FAccordionControl.lifted(
                expanded: (_) => _guideExpanded,
                onChange: (_, value) => setState(() => _guideExpanded = value),
              ),
              children: [
                FAccordionItem(
                  title: const Text('DeepSeek Harness · Agent Teams'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '1. 在 Magpie 的 Agents 页面选择 DeepSeek Harness，设置模型或路由分组。',
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '2. 在 DSH 新建根会话，开启 Use Agent Teams。已有会话保留原来的模型和协作模式。',
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '3. 先完成一次简单模型请求，再开始并行任务。Superagent 使用独立 profile，常驻任务还需配置监听来源和机器人身份。',
                      ),
                      const SizedBox(height: 12),
                      FButton(
                        variant: FButtonVariant.outline,
                        size: FButtonSizeVariant.sm,
                        mainAxisSize: MainAxisSize.min,
                        onPress: _guide,
                        prefix: const Icon(FLucideIcons.externalLink),
                        child: const Text('打开接入指南'),
                      ),
                      if (_guideUnavailable)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: SelectableText(
                            '浏览器未能打开。可访问 github.com/SailingLoong/LoongPass 的 docs/dsh-multi-agent.md。',
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}
