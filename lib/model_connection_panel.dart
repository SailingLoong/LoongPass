import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart' show SelectableText;

import 'model_connection.dart';
import 'model_workspace_view_model.dart';
import 'plugin_model_accounts.dart';

Future<void> showModelConnectionSheet(
  BuildContext context,
  ModelWorkspaceViewModel vm,
  ModelConnection connection,
) => showFSheet<void>(
  context: context,
  side: FLayout.rtl,
  mainAxisMaxRatio: 1,
  constraints: const BoxConstraints(maxWidth: 462),
  draggable: false,
  builder: (context) => ListenableBuilder(
    listenable: Listenable.merge([vm, vm.service]),
    builder: (context, _) => Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        color: context.theme.colors.background,
        border: Border(left: BorderSide(color: context.theme.colors.border)),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('模型连接', style: context.theme.typography.body.xs),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '连接设置',
                    style: context.theme.typography.display.sm,
                  ),
                ),
                FButton.icon(
                  variant: FButtonVariant.ghost,
                  semanticsLabel: '关闭连接设置',
                  onPress: () => Navigator.pop(context),
                  child: const Icon(FLucideIcons.x),
                ),
              ],
            ),
            const SizedBox(height: 20),
            FSwitch(
              value: vm.service.enabled,
              enabled: !vm.busy,
              leadingLabel: true,
              label: const Text('本机模型服务'),
              description: Text(vm.service.running ? '本机服务运行中' : '本机服务已关闭'),
              onChange: vm.enableService,
            ),
            if (vm.service.error != null) const Text('服务启动未完成，请检查本机端口。'),
            const SizedBox(height: 24),
            Text('开放给 Magpie 的账号', style: context.theme.typography.body.lg),
            if (vm.service.grants.isEmpty) const Text('暂无可开放的账号。'),
            for (final grant in vm.service.grants)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: FSwitch(
                  key: ValueKey(grant.account.key),
                  value: grant.enabled,
                  enabled: !vm.busy && !grant.authorizationRequired,
                  leadingLabel: true,
                  label: Text(grant.account.label),
                  description: Text(
                    '${modelSourceName(grant.account.provider)}${grant.authorizationRequired ? ' · 需要授权' : ''}',
                  ),
                  onChange: (value) => vm.authorize(grant.account.key, value),
                ),
              ),
            if (vm.error != null) Text(vm.error!),
            const SizedBox(height: 16),
            ModelConnectionPanel(connection: connection, enabled: !vm.busy),
          ],
        ),
      ),
    ),
  ),
);

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
      final saved = connection.savedAccounts;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Magpie 授权记录', style: titleStyle),
          const SizedBox(height: 6),
          Text('已保存的所选账号：${saved ?? '未确认'} / $count'),
          Text(
            '最近检查：${checked?.toLocal().toString().substring(0, 19) ?? '尚未检查'}',
          ),
          const SizedBox(height: 6),
          Text('模型调用尚需在客户端验证。', style: context.theme.typography.body.xs),
          if (count == 0) const Text('请选择可用账号，再开启本机模型服务。'),
          const SizedBox(height: 10),
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
          if (connection.error != null) ...[
            const SizedBox(height: 10),
            Text(switch (connection.error!) {
              ModelConnectionFailure.notReady => '请先开启本机模型服务，并选择至少一个有效账号。',
              ModelConnectionFailure.saveFailed =>
                '授权保存未完成。请检查连接状态，确认 Magpie 可用后重试连接。',
              ModelConnectionFailure.changed => '账号或服务状态已变化，请重新检查。',
            }, style: TextStyle(color: context.theme.colors.error)),
          ],
          if (result != null) ...[
            const SizedBox(height: 10),
            if (!result.executableFound)
              const Text('未找到 Magpie 命令。请安装官方 Magpie，并确认命令可用。')
            else ...[
              Text(
                result.gatewayReady == true
                    ? 'Magpie 网关可达。'
                    : 'Magpie 网关不可达。请启动 Magpie，并检查其网关设置。',
              ),
              const SizedBox(height: 6),
              if (saved == null)
                const Text(
                  '授权记录未确认。请在 Magpie 检查 LoongPass 插件状态；必要时更新 Magpie 后重试。',
                )
              else if (saved != count)
                const Text('请重新连接 Magpie 同步授权。'),
            ],
          ],
          const SizedBox(height: 8),
          FAccordion(
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
        ],
      );
    },
  );
}
