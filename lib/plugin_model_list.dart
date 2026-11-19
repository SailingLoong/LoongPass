import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'plugin_model_catalog.dart';
import 'plugin_model_accounts.dart';

class PluginModelList extends StatelessWidget {
  const PluginModelList({
    super.key,
    required this.models,
    required this.busy,
    required this.onSelect,
    required this.onPublish,
    required this.onReorder,
    this.filtered = false,
  });
  final List<PluginModel> models;
  final bool busy;
  final bool filtered;
  final ValueChanged<String> onSelect;
  final void Function(String, bool) onPublish;
  final void Function(int, int) onReorder;

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
          if (!busy && !filtered) onReorder(from, to);
        },
        proxyDecorator: (child, index, animation) =>
            ColoredBox(color: context.theme.colors.muted, child: child),
        itemBuilder: (context, index) {
          final model = models[index], preferred = models[index].preferred;
          final muted = context.theme.typography.body.xs.copyWith(
            color: context.theme.colors.mutedForeground,
          );
          final name = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FButton(
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                onPress: () => onSelect(model.id),
                child: Flexible(child: Text(model.name, softWrap: true)),
              ),
              Text(
                '${model.availableAccounts} 个可用账号 · ${model.enabled ? '参与 Auto' : '不参与 Auto'}',
                style: muted,
              ),
            ],
          );
          final recommendation = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                preferred == null
                    ? '暂无可用账号'
                    : '新会话首选 ${preferred.account.label}',
                style: muted,
              ),
              if (preferred != null)
                Text(modelExpiryText(preferred), style: muted),
            ],
          );
          final move = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FButton.icon(
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                semanticsLabel: '上移 ${model.name}',
                onPress: busy || index == 0
                    ? null
                    : () => onReorder(index, index - 1),
                child: const Icon(FLucideIcons.arrowUp, size: 14),
              ),
              FButton.icon(
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                semanticsLabel: '下移 ${model.name}',
                onPress: busy || index == models.length - 1
                    ? null
                    : () => onReorder(index, index + 1),
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
                if (!filtered)
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
                if (wide) ...[
                  Expanded(flex: 3, child: name),
                  const SizedBox(width: 8),
                  Expanded(flex: 4, child: recommendation),
                  if (!filtered) move,
                ] else
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        name,
                        const SizedBox(height: 6),
                        recommendation,
                        if (!filtered) move,
                      ],
                    ),
                  ),
                const SizedBox(width: 8),
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
