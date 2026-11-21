import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'plugin_model_catalog.dart';

class PluginModelList extends StatelessWidget {
  const PluginModelList({
    super.key,
    required this.models,
    required this.busy,
    required this.onSelect,
    required this.onPublish,
    required this.candidates,
    required this.onMove,
    this.filtered = false,
  });
  final List<PluginModel> models;
  final bool busy;
  final bool filtered;
  final ValueChanged<String> onSelect;
  final void Function(String, bool) onPublish;
  final List<PluginModel>? candidates;
  final void Function(String, String) onMove;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final wide =
          box.maxWidth >= 660 * MediaQuery.textScalerOf(context).scale(14) / 14;
      return ReorderableList(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: models.length,
        onReorderItem: (from, to) {
          if (!busy && !filtered && candidates != null) {
            onMove(models[from].id, models[to].id);
          }
        },
        proxyDecorator: (child, index, animation) =>
            ColoredBox(color: context.theme.colors.muted, child: child),
        itemBuilder: (context, index) {
          final model = models[index];
          final order = candidates;
          final rank = order?.indexWhere((m) => m.id == model.id) ?? -1;
          final muted = context.theme.typography.body.xs.copyWith(
            color: context.theme.colors.mutedForeground,
          );
          final name = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!model.official)
                Text(model.name, style: context.theme.typography.body.md)
              else
                FButton(
                  variant: FButtonVariant.ghost,
                  size: FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => onSelect(model.id),
                  child: Flexible(child: Text(model.name, softWrap: true)),
                ),
              Text(
                order == null
                    ? '${model.availableAccounts} 个可用账号 · ${model.enabled ? '参与 Auto' : '不参与 Auto'}'
                    : '${model.official ? '' : '渠道名称 · '}${model.availableAccounts} 个可用账号',
                style: muted,
              ),
            ],
          );
          final move = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FButton.icon(
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                semanticsLabel: '上移 ${model.name}',
                onPress: busy || order == null || rank <= 0
                    ? null
                    : () => onMove(model.id, order[rank - 1].id),
                child: const Icon(FLucideIcons.arrowUp, size: 14),
              ),
              FButton.icon(
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                semanticsLabel: '下移 ${model.name}',
                onPress:
                    busy ||
                        order == null ||
                        rank < 0 ||
                        rank == order.length - 1
                    ? null
                    : () => onMove(model.id, order[rank + 1].id),
                child: const Icon(FLucideIcons.arrowDown, size: 14),
              ),
            ],
          );
          return Container(
            key: ValueKey('model-${model.id}'),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: context.theme.colors.border),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (order != null)
                  Text((rank + 1).toString().padLeft(2, '0'), style: muted),
                if (order != null && !filtered)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ReorderableDragStartListener(
                      index: index,
                      enabled: !busy,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: Icon(
                          FLucideIcons.gripVertical,
                          size: 18,
                          color: context.theme.colors.mutedForeground,
                        ),
                      ),
                    ),
                  ),
                if (order == null)
                  Expanded(child: name)
                else if (wide) ...[
                  Expanded(child: name),
                  move,
                ] else
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [name, const SizedBox(height: 6), move],
                    ),
                  ),
                const SizedBox(width: 8),
                if (order == null)
                  FSwitch(
                    key: ValueKey('model-published-${model.id}'),
                    semanticsLabel: '在 Magpie 中显示 ${model.name}',
                    value: model.published,
                    enabled: !busy,
                    onChange: (value) => onPublish(model.id, value),
                  ),
              ],
            ),
          );
        },
      );
    },
  );
}

class ExcludedAutoModels extends StatelessWidget {
  const ExcludedAutoModels({
    super.key,
    required this.models,
    required this.searching,
    required this.busy,
    required this.onJoin,
  });
  final List<PluginModel> models;
  final bool searching;
  final bool busy;
  final ValueChanged<String> onJoin;

  @override
  Widget build(BuildContext context) {
    final items = Column(
      children: [
        for (final model in models)
          FItem(
            title: Text(model.name),
            suffix: const Text('加入 Auto'),
            semanticsLabel: '将 ${model.name} 加入 Auto',
            enabled: !busy,
            onPress: () => onJoin(model.id),
          ),
      ],
    );
    if (searching) return items;
    return FAccordion(
      children: [
        FAccordionItem(title: Text('未参与（${models.length}）'), child: items),
      ],
    );
  }
}
