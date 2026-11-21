import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'desktop_theme.dart';
import 'model_workspace_view_model.dart';
import 'model_auto_summary.dart';
import 'plugin_accounts.dart';
import 'plugin_application.dart';
import 'plugin_model_accounts.dart';
import 'plugin_model_list.dart';
import 'model_connection_panel.dart';
import 'workspace_page.dart';

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
  late var vm = ModelWorkspaceViewModel(widget.application.models);
  final _search = TextEditingController();
  late String? _localSelection = widget.selectedModelId;

  @override
  void didUpdateWidget(PluginModelServicesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.application.models != widget.application.models) {
      vm.dispose();
      vm = ModelWorkspaceViewModel(widget.application.models);
      _search.clear();
    }
    if (oldWidget.selectedModelId != widget.selectedModelId) {
      _localSelection = widget.selectedModelId;
    }
  }

  void _select(String? id) {
    final callback = widget.onSelectModel;
    if (callback != null) {
      callback(id);
    } else {
      setState(() => _localSelection = id);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    vm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.application;
    return ListenableBuilder(
      listenable: Listenable.merge([vm, app.models, app.connection]),
      builder: (context, _) {
        final id = widget.onSelectModel == null
            ? _localSelection
            : widget.selectedModelId;
        final auto = id == 'auto';
        final (:selected, :candidates, :excluded, :visible, :noSources) = vm
            .snapshot(id);
        return WorkspacePage(
          title: selected?.name ?? (auto ? 'LoongPass Auto' : '模型连接'),
          subtitle: selected != null
              ? '模型名称使用厂商 API 标准 ID。'
              : auto
              ? null
              : '管理 Magpie 能使用的模型与账号。',
          action: selected == null && !auto
              ? FButton(
                  variant: FButtonVariant.outline,
                  size: FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  prefix: const Icon(FLucideIcons.cable, size: 16),
                  onPress: () =>
                      showModelConnectionSheet(context, vm, app.connection),
                  child: const Text('连接设置'),
                )
              : FButton(
                  variant: FButtonVariant.outline,
                  size: FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  prefix: const Icon(FLucideIcons.arrowLeft, size: 16),
                  onPress: () => _select(null),
                  child: const Text('全部模型'),
                ),
          children: [
            if (app.connection.busy) const Text('正在更新 Magpie 连接…'),
            if (app.connection.error != null)
              const Text('Magpie 连接配置尚未同步完成。已连接的配置会自动重试，也可在连接设置中重新连接。'),
            if (vm.error != null) Text(vm.error!),
            if (selected != null) ...[
              WorkspaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FSwitch(
                      key: ValueKey('model-published-${selected.id}'),
                      value: selected.published,
                      enabled: !vm.busy,
                      leadingLabel: true,
                      label: const Text('在 Magpie 中显示'),
                      description: Text('打开后可单独选择 ${selected.name}。'),
                      onChange: (value) => vm.publish(selected.id, value),
                    ),
                    const SizedBox(height: 16),
                    FSwitch(
                      key: ValueKey('model-enabled-${selected.id}'),
                      value: selected.enabled,
                      enabled: !vm.busy,
                      leadingLabel: true,
                      label: const Text('参与 Auto'),
                      description: const Text('关闭后 Auto 将跳过此模型，不影响单独选择。'),
                      onChange: (value) => vm.participate(selected.id, value),
                    ),
                  ],
                ),
              ),
              Text('账号来源', style: context.theme.typography.display.sm),
              PluginModelAccounts(
                key: ValueKey(selected.id),
                model: selected,
                busy: vm.busy,
                onOpenAccount: widget.onOpenAccount,
                onEnable: (key, value) =>
                    vm.enableSource(selected.id, key, value),
                onAuthorize: vm.authorize,
              ),
            ] else if (!auto && noSources) ...[
              Text('暂无账号来源', style: context.theme.typography.body.lg),
              const SizedBox(height: 8),
              const Text('在「账号与积分」中添加支持模型服务的账号。'),
            ] else ...[
              if (auto)
                ModelAutoSettings(
                  routing: app.connection.routing,
                  running: app.models.running,
                  busy: vm.busy,
                  onChange: vm.selectPriority,
                )
              else
                ModelAutoSummary(
                  priority: app.connection.autoPriority,
                  onOpen: () => _select('auto'),
                ),
              const SizedBox(height: 20),
              Text(
                auto ? '模型顺序' : '模型目录',
                style: context.theme.typography.body.lg.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 200,
                    child: FTextField(
                      key: const Key('model-search'),
                      hint: '搜索模型、别名或账号',
                      size: FTextFieldSizeVariant.sm,
                      prefixBuilder: (context, style, variants) =>
                          const Icon(FLucideIcons.search, size: 16),
                      control: FTextFieldControl.managed(
                        controller: _search,
                        onChange: (value) => vm.search(value.text),
                      ),
                    ),
                  ),
                  if (!auto)
                    SizedBox(
                      width: 68 + MediaQuery.textScalerOf(context).scale(88),
                      child: FSwitch(
                        key: const Key('show-all-models'),
                        value: vm.showAll,
                        label: const Text('显示全部模型'),
                        onChange: vm.setShowAll,
                      ),
                    ),
                  if (vm.query.isNotEmpty && !auto)
                    FButton(
                      key: const Key('retain-models'),
                      variant: FButtonVariant.outline,
                      size: FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: vm.busy || visible.isEmpty
                          ? null
                          : () => vm.retain(visible),
                      child: Flexible(
                        child: Text('Auto 仅使用筛选结果（${visible.length}）'),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (!auto)
                Container(
                  color: context.desktopPalette.sidebar,
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      const Expanded(child: Text('模型名称')),
                      Flexible(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: const Text('在 Magpie 中显示'),
                        ),
                      ),
                    ],
                  ),
                ),
              if (visible.isEmpty && (vm.query.isEmpty || excluded.isEmpty))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    vm.query.isNotEmpty
                        ? '没有匹配的模型。可搜索模型、别名或账号。'
                        : auto
                        ? '暂无参与 Auto 的模型。'
                        : '暂无单独显示的模型。打开“显示全部模型”后，开启需要的模型。',
                  ),
                ),
              PluginModelList(
                models: visible,
                candidates: auto ? candidates : null,
                busy: vm.busy,
                onSelect: _select,
                onPublish: vm.publish,
                onMove: vm.move,
                filtered: vm.query.isNotEmpty,
              ),
              if (excluded.isNotEmpty)
                ExcludedAutoModels(
                  models: excluded,
                  searching: vm.query.isNotEmpty,
                  busy: vm.busy,
                  onJoin: (id) => vm.participate(id, true),
                ),
            ],
          ],
        );
      },
    );
  }
}
