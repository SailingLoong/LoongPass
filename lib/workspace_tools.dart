import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'model_service.dart';
import 'ui_preferences.dart';
import 'app_updates.dart';

class ModelServicesPage extends StatefulWidget {
  const ModelServicesPage({super.key, this.service});
  final ModelService? service;
  @override
  State<ModelServicesPage> createState() => _ModelServicesPageState();
}

class _ModelServicesPageState extends State<ModelServicesPage> {
  String? _providerId, _accountId, _message;
  final _accounts = <String, Future<List<ModelAccount>>>{};
  @override
  void initState() {
    super.initState();
    widget.service?.onChanged = _changed;
    _synchronise();
  }

  void _synchronise() {
    final service = widget.service;
    if (service == null) return;
    for (final provider in service.providers) {
      _accounts.putIfAbsent(provider.id, provider.accounts);
      _providerId ??= provider.id;
    }
  }

  void _changed() {
    if (mounted) setState(_synchronise);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _message = null);
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _message = '操作未完成，请核对账号授权和本机端口后重试。');
    }
  }

  Future<void> _copy(String text, String message) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) setState(() => _message = message);
  }

  @override
  void dispose() {
    widget.service?.onChanged = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final locked = service == null || service.busy;
    final providers = service?.providers.toList() ?? [];
    return WorkspacePage(
      title: '模型服务',
      subtitle: '把已保存账号的模型连接到 Magpie，供 Claude Code 等软件使用。',
      children: [
        WorkspaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.route_outlined, size: 22),
                  const SizedBox(width: 10),
                  const Text(
                    'Magpie',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  Chip(
                    label: Text(service?.running == true ? '本地服务运行中' : '尚未启动'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text('每个账号保留独立连接与可用模型。模型目录来自该账号的官方配置，余额以平台查询为准。'),
              const SizedBox(height: 16),
              if (service == null)
                const Text('本地模型服务当前在 macOS 提供。')
              else ...[
                DropdownButtonFormField<String>(
                  initialValue: _providerId,
                  decoration: const InputDecoration(labelText: '模型来源'),
                  items: [
                    for (final p in providers)
                      DropdownMenuItem(value: p.id, child: Text(p.name)),
                  ],
                  onChanged: locked
                      ? null
                      : (v) => setState(() {
                          _providerId = v;
                          _accountId = null;
                        }),
                ),
                const SizedBox(height: 12),
                FutureBuilder<List<ModelAccount>>(
                  future: _accounts[_providerId],
                  builder: (context, snapshot) {
                    final rows = snapshot.data ?? const <ModelAccount>[];
                    return DropdownButtonFormField<String>(
                      key: ValueKey((
                        _providerId,
                        rows.map((a) => a.id).join(','),
                      )),
                      initialValue: rows.any((a) => a.id == _accountId)
                          ? _accountId
                          : null,
                      decoration: const InputDecoration(labelText: '已保存账号'),
                      items: [
                        for (final a in rows)
                          DropdownMenuItem(value: a.id, child: Text(a.label)),
                      ],
                      onChanged: locked
                          ? null
                          : (v) => setState(() => _accountId = v),
                    );
                  },
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed:
                          locked || _providerId == null || _accountId == null
                          ? null
                          : () => _run(() async {
                              await service.addAccount(
                                providerId: _providerId!,
                                accountId: _accountId!,
                              );
                            }),
                      child: const Text('添加账号连接'),
                    ),
                    TextButton(
                      onPressed: locked
                          ? null
                          : () => setState(() {
                              for (final p in providers) {
                                _accounts[p.id] = p.accounts();
                              }
                            }),
                      child: const Text('重新读取已保存账号'),
                    ),
                    OutlinedButton(
                      onPressed: locked || service.bindings.isEmpty
                          ? null
                          : () => _run(
                              service.running ? service.stop : service.start,
                            ),
                      child: Text(service.running ? '停止本地服务' : '启动本地服务'),
                    ),
                  ],
                ),
                if (service.endpoint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: SelectableText(service.endpoint.toString()),
                  ),
                if (service.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(switch (service.error) {
                      'client_version_unavailable' => '请先安装并打开该来源的官方客户端，再刷新目录。',
                      'unsupported_client_version' => '请更新该来源的官方客户端后重试。',
                      'port_unavailable' => '本机服务端口被占用，请关闭占用程序后重试。',
                      'save_failed' => '连接设置未保存，请重试。',
                      'invalid_settings' => '连接设置无法读取，服务未随应用启动。',
                      _ => '连接不可用，请核对账号后重试。',
                    }),
                  ),
              ],
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_message!),
                ),
            ],
          ),
        ),
        if (service != null)
          for (final binding in service.bindings)
            WorkspaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: FutureBuilder<List<ModelAccount>>(
                          future: _accounts[binding.providerId],
                          builder: (context, snapshot) {
                            final rows =
                                (snapshot.data ?? const <ModelAccount>[]).where(
                                  (a) => a.id == binding.accountId,
                                );
                            final sources = providers.where(
                              (p) => p.id == binding.providerId,
                            );
                            return Text(
                              '${sources.isEmpty ? binding.providerId : sources.first.name} · ${rows.isEmpty ? binding.accountId : rows.first.label}',
                              style: Theme.of(context).textTheme.titleMedium,
                            );
                          },
                        ),
                      ),
                      Switch(
                        value: binding.enabled,
                        onChanged: locked
                            ? null
                            : (v) =>
                                  _run(() => service.setEnabled(binding.id, v)),
                      ),
                    ],
                  ),
                  if (binding.models.isEmpty)
                    const Text('暂无可用模型，请刷新目录或重新授权账号。')
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (final model in binding.models)
                          Chip(label: Text(model.id)),
                      ],
                    ),
                  if (binding.queriedAt != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '目录查询时间：${binding.queriedAt!.toLocal().toString().split('.').first}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  if (binding.error != null)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('目录更新未完成，请核对账号授权后刷新。'),
                    ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: locked
                            ? null
                            : () =>
                                  _run(() => service.refreshModels(binding.id)),
                        child: const Text('刷新模型目录'),
                      ),
                      OutlinedButton.icon(
                        key: ValueKey('copy-${binding.id}'),
                        onPressed: service.importUriFor(binding.id) == null
                            ? null
                            : () => _run(
                                () => _copy(
                                  service.importUriFor(binding.id).toString(),
                                  '接入链接已复制。首次导入此来源时使用此链接。',
                                ),
                              ),
                        icon: const Icon(Icons.copy_outlined, size: 17),
                        label: const Text('复制 Magpie 接入链接'),
                      ),
                      TextButton(
                        onPressed: () => _run(
                          () => _copy(
                            binding.key,
                            '账号密钥已复制，请添加到 Magpie 中此来源的密钥列表。',
                          ),
                        ),
                        child: const Text('复制账号密钥'),
                      ),
                      TextButton(
                        onPressed: locked
                            ? null
                            : () => _run(() => service.revoke(binding.id)),
                        child: const Text('撤销连接'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        const WorkspaceCard(
          child: Text(
            '首次导入某个来源后，将同一来源的其他账号密钥加入 Magpie 的同一服务。启用账号轮换，并设置错误直接返回、关闭等待重试。使用 Claude Code 时，启动前设置 CLAUDE_CODE_MAX_RETRIES=0 和 CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1，并关闭模型 fallback，避免客户端自行重发失败或中断的请求。请使用支持这些选项的新版 Magpie。连接仅监听本机，启动设置会随 LoongPass 恢复。',
          ),
        ),
      ],
    );
  }
}

class WorkspaceSettingsPage extends StatelessWidget {
  const WorkspaceSettingsPage({
    super.key,
    required this.preferences,
    this.updates,
  });
  final UiPreferences preferences;
  final AppUpdates? updates;
  @override
  Widget build(BuildContext context) {
    final selectorWidth = MediaQuery.textScalerOf(context).scale(100) + 32;
    return ListenableBuilder(
      listenable: preferences,
      builder: (context, _) => WorkspacePage(
        title: '设置',
        subtitle: '外观、应用布局与更新。',
        children: [
          if (updates != null)
            WorkspaceCard(child: AppUpdateCard(updates: updates!)),
          if (preferences.error != null)
            WorkspaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(preferences.error!),
                  TextButton(
                    onPressed: preferences.retrySave,
                    child: const Text('重新保存界面偏好'),
                  ),
                ],
              ),
            ),
          WorkspaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '外观与列表',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('主题'),
                  trailing: SizedBox(
                    width: selectorWidth,
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<ThemeMode>(
                          value: preferences.themeMode,
                          isDense: true,
                          isExpanded: true,
                          items: const [
                            DropdownMenuItem(
                              value: ThemeMode.system,
                              child: Text('跟随系统'),
                            ),
                            DropdownMenuItem(
                              value: ThemeMode.light,
                              child: Text('浅色'),
                            ),
                            DropdownMenuItem(
                              value: ThemeMode.dark,
                              child: Text('深色'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v != null) preferences.setTheme(v);
                          },
                        ),
                      ),
                    ),
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('账号行距'),
                  trailing: SizedBox(
                    width: selectorWidth,
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<bool>(
                          value: preferences.comfortable,
                          isDense: true,
                          isExpanded: true,
                          items: const [
                            DropdownMenuItem(value: false, child: Text('紧凑')),
                            DropdownMenuItem(value: true, child: Text('舒适')),
                          ],
                          onChanged: (v) {
                            if (v != null) preferences.setComfortable(v);
                          },
                        ),
                      ),
                    ),
                  ),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('精简应用栏'),
                  subtitle: const Text('保留应用图标，悬停查看完整名称。'),
                  value: preferences.collapsed,
                  onChanged: preferences.setCollapsed,
                ),
              ],
            ),
          ),
          WorkspaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '应用排序',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                const Text('在左侧上下拖动应用。键盘聚焦应用后，也可用 Option + ↑ / ↓ 调整。顺序会保存在本机。'),
                TextButton(
                  onPressed: preferences.resetOrder,
                  child: const Text('恢复默认应用顺序'),
                ),
              ],
            ),
          ),
          const WorkspaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('运行与数据', style: TextStyle(fontWeight: FontWeight.w600)),
                SizedBox(height: 8),
                Text(
                  '授权以明文保存在本机应用私有目录。辅助签到与活动领取只在 LoongPass 运行期间执行；开关在各账号详情中设置。',
                ),
                SizedBox(height: 8),
                Text('界面偏好单独保存，不包含账号凭据、余额或领取记录。'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class WorkspacePage extends StatelessWidget {
  const WorkspacePage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
  });
  final String title, subtitle;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text(title, style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 6),
      Text(
        subtitle,
        style: Theme.of(context).textTheme.bodyLarge!.copyWith(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 20),
      ...children,
    ],
  );
}

class WorkspaceCard extends StatelessWidget {
  const WorkspaceCard({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(padding: const EdgeInsets.all(18), child: child),
  );
}
