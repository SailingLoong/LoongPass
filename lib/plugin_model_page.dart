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
      listenable: service,
      builder: (context, _) {
        final catalog = service.catalog;
        final selectedId = widget.onSelectModel == null
            ? widget.selectedModelId ?? _localSelection
            : widget.selectedModelId;
        final selected = catalog.where((m) => m.id == selectedId).firstOrNull;
        final query = _search.text.trim().toLowerCase();
        final visible = catalog
            .where(
              (m) =>
                  '${m.id} ${m.name} ${m.bindings.map((b) => '${b.nativeId} ${b.account.label} ${b.account.provider}').join(' ')}'
                      .toLowerCase()
                      .contains(query),
            )
            .toList();
        return WorkspacePage(
          title: selected?.name ?? 'loongpass/auto',
          subtitle: '同会话、同模型优先复用账号。新会话优先使用最早到期的剩余额度。',
          children: [
            if (_message != null) WorkspaceCard(child: Text(_message!)),
            if (selectedId != null)
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
                    selected.official
                        ? selected.publicId
                        : '标准名称待核实 · ${selected.id}',
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
                      'loongpass/auto 按下列顺序选择已确认标准名称的模型。拖动或使用上下箭头调整。',
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
                    if (visible.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text('暂无匹配模型。可在账号与积分添加账号，或修改搜索条件。'),
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
                        order.insert(to, order.removeAt(from));
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
                              enabled: !_busy && grant.account.active,
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
