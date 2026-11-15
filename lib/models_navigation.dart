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
    if (compact) {
      return FPopoverMenu(
        control: FPopoverControl.lifted(
          shown: active && preferences.modelsExpanded,
          onChange: preferences.setModelsExpanded,
        ),
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
        builder: (context, controller, _) => Semantics(
          expanded: active && preferences.modelsExpanded,
          child: navigation,
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(expanded: preferences.modelsExpanded, child: navigation),
        if (preferences.modelsExpanded)
          Flexible(
            child: Container(
              margin: const EdgeInsets.only(left: 16, top: 4, bottom: 4),
              padding: const EdgeInsets.only(left: 8),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: context.theme.colors.border),
                ),
              ),
              child: ListView(
                key: const PageStorageKey('model-list'),
                primary: false,
                shrinkWrap: true,
                padding: EdgeInsets.zero,
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
                    SidebarNavigationButton(
                      key: ValueKey('model-nav-$id'),
                      label: id,
                      icon: const Icon(FLucideIcons.dot, size: 16),
                      compact: false,
                      nested: true,
                      maxLines: 2,
                      selected: active && id == selectedModelId,
                      onPressed: () => onSelectModel(id),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
