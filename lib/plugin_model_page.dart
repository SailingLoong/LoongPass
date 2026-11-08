import 'package:flutter/material.dart';

import 'plugin_application.dart';
import 'magpie_connection.dart';
import 'workspace_tools.dart' show WorkspacePage, WorkspaceCard;

class PluginModelServicesPage extends StatefulWidget {
  const PluginModelServicesPage({super.key, required this.application});
  final PluginApplication application;
  @override
  State<PluginModelServicesPage> createState() =>
      _PluginModelServicesPageState();
}

class _PluginModelServicesPageState extends State<PluginModelServicesPage> {
  bool _busy = false;
  String? _message;
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted)
        setState(() => _message = '操作未完成。请确认 Magpie 已安装并启动，以及本地服务端口可用。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.application, service = app.models;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) => WorkspacePage(
        title: '模型服务',
        subtitle: '通过 Magpie 使用已保存账号的原生模型、分组和恢复能力。',
        children: [
          WorkspaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('本机模型服务'),
                  subtitle: Text(service.running ? '正在运行' : '已停止'),
                  value: service.enabled,
                  onChanged: _busy
                      ? null
                      : (value) => _run(() => service.setEnabled(value)),
                ),
                const Text(
                  '选择可供 Magpie 使用的账号。模型分组、路由和 Claude Code 等客户端的接入由 Magpie 管理。',
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed:
                      _busy ||
                          !service.running ||
                          !service.grants.any(
                            (g) => g.enabled && g.account.active,
                          )
                      ? null
                      : () => _run(() async {
                          await MagpieConnection().connect(
                            app.bridgePath,
                            service.endpoint!,
                            service.grants,
                            legacyKeys: service.legacyKeys,
                            saveBackup: service.saveConnectionBackup,
                          );
                          if (mounted)
                            setState(
                              () => _message =
                                  '账号授权已保存到 Magpie。可在 Magpie 中选择模型或路由分组。',
                            );
                        }),
                  icon: const Icon(Icons.link),
                  label: Text(_busy ? '正在处理…' : '连接 Magpie'),
                ),
                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_message!),
                  ),
                if (service.error != null) const Text('本地服务尚未启动，请核对端口占用后重新开启。'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'ZCode 的 -Trial 模型仅使用赠送额度。普通模型优先使用可用赠送权益，再使用账号已有套餐；不会购买或充值。',
          ),
          const SizedBox(height: 12),
          for (final grant in service.grants)
            WorkspaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(grant.account.label),
                    subtitle: Text(
                      '${grant.account.provider} · ${grant.account.realm} · ${grant.account.models.length} 个模型',
                    ),
                    value: grant.enabled,
                    onChanged: _busy || !grant.account.active
                        ? null
                        : (value) => _run(
                            () => service.enable(grant.account.key, value),
                          ),
                  ),
                  if (!grant.account.active) const Text('账号需要重新授权。'),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final model in grant.account.models)
                        Chip(
                          label: Text(
                            '${model['name'] ?? model['id']}${grant.account.provider == 'zcode'
                                ? (model['id'] as String).toLowerCase().endsWith('-trial')
                                      ? ' · 仅赠送'
                                      : ' · 赠送优先，可转套餐'
                                : ''}',
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
