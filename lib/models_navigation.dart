import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'app_navigation_item.dart';
import 'ui_preferences.dart';

/// Model identity and order come from the model service. This widget owns no
/// routing, account or quota state.
class ModelsNavigation extends StatelessWidget {
  const ModelsNavigation({
    super.key,
    required this.preferences,
    required this.compact,
    required this.active,
    required this.modelIds,
    required this.selectedModelId,
    required this.onOpen,
    required this.onSelectModel,
  });

  final UiPreferences preferences;
  final bool compact, active;
  final List<String> modelIds;
  final String? selectedModelId;
  final VoidCallback onOpen;
  final ValueChanged<String> onSelectModel;

  @override
  Widget build(BuildContext context) {
    final navigation = SidebarNavigationButton(
      key: const Key('nav-models'),
      label: '模型连接',
      icon: const Icon(FLucideIcons.route, size: 18),
      compact: compact,
      selected: active,
      onPressed: onOpen,
    );
    Widget disclosure(VoidCallback onPress, bool expanded) => Semantics(
      expanded: expanded,
      child: SizedBox.square(
        dimension: 32,
        child: FButton.icon(
          key: const Key('toggle-models'),
          variant: FButtonVariant.ghost,
          size: FButtonSizeVariant.sm,
          semanticsLabel: expanded ? '收起模型列表' : '展开模型列表',
          onPress: onPress,
          child: Icon(
            expanded ? FLucideIcons.chevronDown : FLucideIcons.chevronRight,
            size: 16,
          ),
        ),
      ),
    );
    if (compact) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          navigation,
          FPopoverMenu(
            menuAnchor: Alignment.topLeft,
            childAnchor: Alignment.topRight,
            menuBuilder: (context, controller, _) => [
              FItemGroup(
                children: [
                  if (modelIds.isEmpty)
                    FItem(title: const Text('暂无模型'), enabled: false),
                  for (final id in modelIds)
                    FItem(
                      key: ValueKey('model-nav-$id'),
                      title: Text(id),
                      suffix: active && id == selectedModelId
                          ? const Icon(FLucideIcons.check, size: 16)
                          : null,
                      onPress: () {
                        onSelectModel(id);
                        controller.hide();
                      },
                    ),
                ],
              ),
            ],
            builder: (context, controller, _) => disclosure(
              controller.toggle,
              controller.status.isForwardOrCompleted,
            ),
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: navigation),
            const SizedBox(width: 4),
            disclosure(
              () => preferences.setModelsExpanded(!preferences.modelsExpanded),
              preferences.modelsExpanded,
            ),
          ],
        ),
        if (preferences.modelsExpanded)
          Expanded(
            child: ListView(
              key: const PageStorageKey('model-list'),
              primary: false,
              padding: const EdgeInsets.only(left: 12, top: 4, bottom: 8),
              children: [
                if (modelIds.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      '暂无模型',
                      style: context.theme.typography.body.sm,
                    ),
                  ),
                for (final id in modelIds)
                  FTooltip(
                    tipBuilder: (context, controller) => Text(id),
                    child: FButton(
                      key: ValueKey('model-nav-$id'),
                      variant: active && id == selectedModelId
                          ? FButtonVariant.secondary
                          : FButtonVariant.ghost,
                      size: FButtonSizeVariant.sm,
                      selected: active && id == selectedModelId,
                      mainAxisAlignment: MainAxisAlignment.start,
                      mainAxisSize: MainAxisSize.max,
                      onPress: () => onSelectModel(id),
                      child: Flexible(
                        child: Text(
                          id,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
