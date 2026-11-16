import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'plugin_accounts.dart';
import 'plugin_application.dart';
import 'plugin_model_accounts.dart';
import 'plugin_model_list.dart';
import 'model_connection_panel.dart';
import 'workspace_tools.dart' show WorkspacePage, WorkspaceCard;

class PluginModelServicesPage extends StatefulWidget {
  const PluginModelServicesPage({
    super.key,
    required this.application,
    this.selectedModelId,
    this.onSelectModel,
    this.onOpenAccount,
  });
  final PluginApplication application;
  final String? selectedModelId;
  final ValueChanged<String?>? onSelectModel;
  final ValueChanged<PluginAccount>? onOpenAccount;
  @override
  State<PluginModelServicesPage> createState() =>
      _PluginModelServicesPageState();
}

class _PluginModelServicesPageState extends State<PluginModelServicesPage> {
  bool _busy = false;
  bool _showAll = false;
  final _expanded = <int>{};
  final _search = TextEditingController();
  String? _localSelection;
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
      if (mounted) setState(() => _message = '设置保存失败，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _select(String? id) {
    if (widget.onSelectModel != null) {
      widget.onSelectModel!(id);
    } else {
      setState(() => _localSelection = id);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.application, service = app.models;
    return ListenableBuilder(
      listenable: Listenable.merge([service, app.connection]),
      builder: (context, _) {
        final catalog = service.catalog;
        final selectedId = widget.onSelectModel == null
            ? widget.selectedModelId ?? _localSelection
            : widget.selectedModelId;
        final selected = catalog.where((m) => m.id == selectedId).firstOrNull;
        final query = _search.text.trim().toLowerCase();
        final visible = catalog
            .where(
              (m) => (_showAll || m.enabled) && m.searchText.contains(query),
            )
            .toList();
        return WorkspacePage(
          title: selected?.name ?? 'loongpass/auto',
          subtitle: '同会话、同模型优先复用账号。新会话优先使用最早到期的剩余额度。',
          children: [
            if (app.connection.busy)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text('正在更新 Magpie 连接…'),
              ),
            if (app.connection.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text('Magpie 连接配置尚未同步完成。已连接的配置会自动重试，也可展开连接设置重新连接。'),
              ),
            if (_message != null) WorkspaceCard(child: Text(_message!)),
            if (selected != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FButton(
                    variant: FButtonVariant.ghost,
                    size: FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    prefix: const Icon(FLucideIcons.arrowLeft, size: 16),
                    onPress: () => _select(null),
                    child: const Text('全部模型'),
                  ),
                ),
              ),
            if (selected != null) ...[
              WorkspaceCard(
                child: FSwitch(
                  value: selected.enabled,
                  enabled: !_busy,
                  leadingLabel: true,
                  label: const Text('启用此模型'),
                  description: Text(
                    '${selected.publicId}${selected.official ? '' : ' · 标准名称待核实'}',
                  ),
                  onChange: (value) =>
                      _run(() => service.setModelEnabled(selected.id, value)),
                ),
              ),
              PluginModelAccounts(
                model: selected,
                busy: _busy,
                onOpenAccount: widget.onOpenAccount,
                onEnable: (key, value) => _run(
                  () => service.setModelAccountEnabled(selected.id, key, value),
                ),
                onAuthorize: (key, value) =>
                    _run(() => service.enable(key, value)),
              ),
            ] else ...[
              WorkspaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'loongpass/auto 按下列顺序选择已启用的模型。拖动或使用上下箭头调整。',
                      style: context.theme.typography.body.sm,
                    ),
                    const SizedBox(height: 12),
                    FTextField(
                      key: const Key('model-search'),
                      hint: '搜索模型、别名或账号',
                      size: FTextFieldSizeVariant.sm,
                      prefixBuilder: (context, style, variants) =>
                          const Icon(FLucideIcons.search, size: 16),
                      control: FTextFieldControl.managed(
                        controller: _search,
                        onChange: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 16,
                      runSpacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FSwitch(
                          key: const Key('show-all-models'),
                          value: _showAll,
                          label: const Text('显示全部模型'),
                          onChange: (value) => setState(() => _showAll = value),
                        ),
                        if (query.isNotEmpty)
                          FButton(
                            key: const Key('retain-models'),
                            variant: FButtonVariant.outline,
                            size: FButtonSizeVariant.sm,
                            mainAxisSize: MainAxisSize.min,
                            onPress: _busy || visible.isEmpty
                                ? null
                                : () => _run(() async {
                                    await service.retainModels(
                                      visible.map((m) => m.id).toSet(),
                                    );
                                    if (mounted)
                                      setState(() => _showAll = false);
                                  }),
                            child: Text('仅保留筛选结果（${visible.length}）'),
                          ),
                      ],
                    ),
                    if (visible.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text('暂无匹配模型。可显示全部模型、修改搜索条件，或在账号与积分添加账号。'),
                      ),
                    PluginModelList(
                      models: visible,
                      busy: _busy,
                      filtered: query.isNotEmpty,
                      onSelect: _select,
                      onEnable: (id, value) =>
                          _run(() => service.setModelEnabled(id, value)),
                      onReorder: (from, to) {
                        final order = catalog.map((m) => m.id).toList();
                        final source = order.indexOf(visible[from].id);
                        final target = order.indexOf(visible[to].id);
                        order.insert(target, order.removeAt(source));
                        _run(() => service.reorderModels(order));
                      },
                    ),
                  ],
                ),
              ),
            ],
            WorkspaceCard(
              child: FAccordion(
                control: FAccordionControl.lifted(
                  expanded: _expanded.contains,
                  onChange: (index, value) => setState(() {
                    value ? _expanded.add(index) : _expanded.remove(index);
                  }),
                ),
                children: [
                  FAccordionItem(
                    title: Text(
                      '连接设置 · ${service.running ? '本机服务运行中' : '本机服务已关闭'}',
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FSwitch(
                          value: service.enabled,
                          label: const Text('本机模型服务'),
                          leadingLabel: true,
                          enabled: !_busy,
                          onChange: (value) =>
                              _run(() => service.setEnabled(value)),
                        ),
                        if (service.error != null)
                          const Text('服务启动未完成，请检查本机端口。'),
                        const SizedBox(height: 12),
                        ModelConnectionPanel(
                          connection: app.connection,
                          enabled: !_busy,
                        ),
                      ],
                    ),
                  ),
                  FAccordionItem(
                    title: Text('账号授权 · ${service.grants.length} 个账号'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final grant in service.grants)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: FSwitch(
                              value: grant.enabled,
                              enabled: !_busy && !grant.authorizationRequired,
                              leadingLabel: true,
                              label: Text(grant.account.label),
                              description: Text(
                                modelSourceName(grant.account.provider),
                              ),
                              onChange: (value) => _run(
                                () => service.enable(grant.account.key, value),
                              ),
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
}
