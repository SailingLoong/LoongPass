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
  final _model = TextEditingController();
  String? _providerId, _accountId, _message;
  bool _selectionHydrated = false;
  ModelProvider? _accountProvider;
  Future<List<ModelAccount>>? _accounts;
  @override
  void initState() {
    super.initState();
    widget.service?.onChanged = _changed;
    _synchronise();
  }

  void _synchronise() {
    final service = widget.service;
    if (service == null || service.busy) return;
    if (!_selectionHydrated && service.providerId != null) {
      _providerId = service.providerId;
      _accountId = service.accountId;
      _model.text = service.model!;
      _selectionHydrated = true;
    }
    if (_providerId == null && service.providers.isNotEmpty) {
      _providerId = service.providers.first.id;
    }
    final providers = service.providers.where((p) => p.id == _providerId);
    final current = providers.isEmpty ? null : providers.first;
    if (!identical(current, _accountProvider)) {
      _reloadAccounts();
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(_synchronise);
  }

  void _reloadAccounts() {
    final providers = widget.service?.providers.where(
      (p) => p.id == _providerId,
    );
    _accountProvider = providers == null || providers.isEmpty
        ? null
        : providers.first;
    _accounts = _accountProvider?.accounts() ?? Future.value([]);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _message = null);
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _message = '连接操作未完成，请核对账号、模型及本机端口。');
    }
  }

  @override
  void dispose() {
    widget.service?.onChanged = null;
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final locked = service == null || service.busy || service.running;
    return WorkspacePage(
      title: '模型服务',
      subtitle: '通过本机 Magpie，让其他软件使用选定账号的模型能力。',
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
              const Text(
                '选择一个来源、账号和官方模型 ID。Magpie 负责模型选择与客户端协议转换，LoongPass 使用该账号的授权发送请求。',
              ),
              const SizedBox(height: 12),
              if (service == null)
                const Text('本地模型服务当前在 macOS 提供。')
              else ...[
                DropdownButtonFormField<String>(
                  initialValue:
                      service.providers.any((p) => p.id == _providerId)
                      ? _providerId
                      : null,
                  decoration: const InputDecoration(labelText: '模型来源'),
                  items: [
                    for (final p in service.providers)
                      DropdownMenuItem(value: p.id, child: Text(p.name)),
                  ],
                  onChanged: locked
                      ? null
                      : (value) => setState(() {
                          _providerId = value;
                          _accountId = null;
                          _reloadAccounts();
                        }),
                ),
                const SizedBox(height: 12),
                FutureBuilder<List<ModelAccount>>(
                  future: _accounts,
                  builder: (context, snapshot) {
                    final accounts = snapshot.data ?? const <ModelAccount>[];
                    return DropdownButtonFormField<String>(
                      key: ValueKey((
                        _providerId,
                        accounts.map((a) => a.id).join(','),
                      )),
                      initialValue: accounts.any((a) => a.id == _accountId)
                          ? _accountId
                          : null,
                      decoration: const InputDecoration(labelText: '已保存账号'),
                      items: [
                        for (final a in accounts)
                          DropdownMenuItem(value: a.id, child: Text(a.label)),
                      ],
                      onChanged: locked
                          ? null
                          : (value) => setState(() => _accountId = value),
                    );
                  },
                ),
                TextButton(
                  onPressed: locked ? null : () => setState(_reloadAccounts),
                  child: const Text('重新读取已保存账号'),
                ),
                TextField(
                  controller: _model,
                  enabled: !locked,
                  decoration: const InputDecoration(
                    labelText: '官方模型 ID',
                    hintText: '使用官方客户端配置中的模型 ID',
                  ),
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
                              await service.configure(
                                providerId: _providerId!,
                                accountId: _accountId!,
                                model: _model.text.trim(),
                              );
                              await service.start();
                            }),
                      child: const Text('保存并启动'),
                    ),
                    OutlinedButton(
                      onPressed: !service.running || service.busy
                          ? null
                          : () => _run(service.stop),
                      child: const Text('停止本地服务'),
                    ),
                    OutlinedButton.icon(
                      onPressed: !service.running
                          ? null
                          : () => _run(() async {
                              await Clipboard.setData(
                                ClipboardData(
                                  text: service.importUri.toString(),
                                ),
                              );
                              if (mounted)
                                setState(
                                  () => _message =
                                      'Magpie 接入链接已复制，请在 Magpie 中导入。',
                                );
                            }),
                      icon: const Icon(Icons.copy_outlined, size: 17),
                      label: const Text('复制 Magpie 接入链接'),
                    ),
                  ],
                ),
                if (service.endpoint != null) ...[
                  const SizedBox(height: 12),
                  SelectableText(service.endpoint.toString()),
                ],
                if (service.lastStatus != null)
                  Text('最近一次上游响应 HTTP ${service.lastStatus}'),
                if (service.error != null)
                  Text(switch (service.error) {
                    'port_unavailable' => '本地端口 3426 不可用，请检查占用后重新启动。',
                    'save_failed' => '连接设置未保存，操作未完成，请重试。',
                    'invalid_settings' => '连接设置无法读取，服务未自动启动。',
                    _ => '本地连接不可用，请核对配置后重试。',
                  }),
              ],
              if (_message != null) ...[
                const SizedBox(height: 10),
                Text(_message!),
              ],
            ],
          ),
        ),
        const WorkspaceCard(
          child: Text(
            '已实测 MiniMax CN 的文本与流式调用。国际版需单独核对账号和模型。当前每个连接固定使用一个账号，失败时返回结果。上游调用可能消耗该账号额度，余额以平台查询为准。服务仅监听本机，启动设置会在下次打开 LoongPass 时恢复。',
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
                  '授权以明文保存在本机应用私有目录。自动签到与活动领取只在 LoongPass 运行期间执行；开关在各账号详情中设置。',
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
