import 'package:flutter/services.dart';
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
  final _autoSearch = TextEditingController();
  late final _path = <String>[?widget.selectedModelId];

  @override
  void didUpdateWidget(PluginModelServicesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.application.models != widget.application.models) {
      vm.dispose();
      vm = ModelWorkspaceViewModel(widget.application.models);
      _search.clear();
    }
    if (oldWidget.selectedModelId != widget.selectedModelId &&
        _path.lastOrNull != widget.selectedModelId) {
      _path
        ..clear()
        ..addAll([?widget.selectedModelId]);
    }
  }

  void _select(String? id) {
    if (id == _path.lastOrNull) return;
    setState(() {
      if (id == null) {
        _path.clear();
      } else if (_path.contains(id)) {
        _path.removeRange(_path.indexOf(id) + 1, _path.length);
      } else {
        _path.add(id);
      }
    });
    widget.onSelectModel?.call(id);
  }

  void _back() {
    if (_path.isEmpty) return;
    setState(_path.removeLast);
    widget.onSelectModel?.call(_path.lastOrNull);
  }

  @override
  void dispose() {
    _search.dispose();
    _autoSearch.dispose();
    vm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      if (_path.isNotEmpty)
        const SingleActivator(LogicalKeyboardKey.escape): _back,
    },
    child: FocusScope(
      child: IndexedStack(
        sizing: StackFit.expand,
        index: _path.length,
        children: [
          _page(null),
          for (final id in _path)
            Focus(key: ValueKey(id), autofocus: true, child: _page(id)),
        ],
      ),
    ),
  );

  Widget _page(String? id) {
    final app = widget.application;
    return ListenableBuilder(
      listenable: Listenable.merge([
        vm,
        app.models,
        app.connection,
        _autoSearch,
      ]),
      builder: (context, _) {
        final auto = id == 'auto';
        final routing = auto ? app.connection.routing : null;
        final (:selected, :visible, :noSources) = vm.snapshot(
          id,
          candidates: routing?.candidates,
          queryOverride: auto ? _autoSearch.text.trim().toLowerCase() : null,
        );
        final query = auto ? _autoSearch.text.trim() : vm.query;
        return WorkspacePage(
          title: selected?.name ?? (auto ? 'LoongPass Auto' : '模型连接'),
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
                  onPress: _back,
                  child: Text(_path.length > 1 ? '返回' : '全部模型'),
                ),
          children: [
            if (app.connection.busy) const Text('正在更新 Magpie 连接…'),
            if (app.connection.error != null)
              const Text('Magpie 连接配置尚未同步完成。已连接的配置会自动重试，也可在连接设置中重新连接。'),
            if (vm.error case final error?
                when selected == null ||
                    !selected.bindings.any(
                      (b) => b.account.key == error.accountKey,
                    ))
              Text(error.message),
            if (selected != null) ...[
              if (selected.official)
                WorkspaceCard(
                  child: FSwitch(
                    key: ValueKey('model-published-${selected.id}'),
                    value: selected.published,
                    enabled: !vm.busy,
                    leadingLabel: true,
                    label: const Text('在 Magpie 中显示并参与 Auto'),
                    onChange: (value) => vm.publish(selected.id, value),
                  ),
                ),
              Text('账号来源', style: context.theme.typography.display.sm),
              PluginModelAccounts(
                key: ValueKey(selected.id),
                model: selected,
                vm: vm,
                onOpenAccount: widget.onOpenAccount,
              ),
            ] else if (!auto && noSources) ...[
              Text('暂无账号来源', style: context.theme.typography.body.lg),
              const SizedBox(height: 8),
              const Text('在「账号与积分」中添加支持模型服务的账号。'),
            ] else ...[
              if (auto)
                ModelAutoSettings(
                  routing: routing!,
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
              if (auto)
                Text(
                  '模型顺序 · 在 Magpie「路由」中调整',
                  style: context.theme.typography.body.lg.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, box) => Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width:
                          box.maxWidth <
                              520 *
                                  MediaQuery.textScalerOf(context).scale(14) /
                                  14
                          ? box.maxWidth
                          : 272,
                      child: FTextField(
                        key: const Key('model-search'),
                        hint: '搜索模型、别名或账号',
                        size: FTextFieldSizeVariant.sm,
                        prefixBuilder: (context, style, variants) =>
                            const Icon(FLucideIcons.search, size: 16),
                        control: FTextFieldControl.managed(
                          controller: auto ? _autoSearch : _search,
                          onChange: (value) {
                            if (!auto) vm.search(value.text);
                          },
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
                  ],
                ),
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
                          child: const Text('Magpie / Auto'),
                        ),
                      ),
                    ],
                  ),
                ),
              if (visible.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    query.isNotEmpty
                        ? '没有匹配的模型。可搜索模型、别名或账号。'
                        : auto
                        ? '暂无可用候选。请在「模型连接」检查已展示的模型和开放的账号。'
                        : '打开“显示全部模型”，选择要在 Magpie 和 Auto 中使用的模型。',
                  ),
                ),
              PluginModelList(
                models: visible,
                candidates: routing?.candidates,
                busy: vm.busy,
                onSelect: _select,
                onPublish: vm.publish,
              ),
            ],
          ],
        );
      },
    );
  }
}
