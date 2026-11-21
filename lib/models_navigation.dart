import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'app_navigation_item.dart';
import 'ui_preferences.dart';

/// Model identity and order come from the model service. This widget owns
/// the currently expanded navigation group.
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

  Widget _content(BuildContext context, {VoidCallback? onSelected}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: ListView(
            key: const PageStorageKey('model-list'),
            primary: false,
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              for (final id in modelIds)
                SidebarNavigationButton(
                  key: ValueKey('model-nav-$id'),
                  label: id == 'auto' ? 'LoongPass Auto' : id,
                  icon: const Icon(FLucideIcons.dot, size: 16),
                  compact: false,
                  nested: true,
                  maxLines: 2,
                  selected: active && id == selectedModelId,
                  onPressed: () {
                    onSelectModel(id);
                    onSelected?.call();
                  },
                ),
              if (modelIds.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('暂无模型', style: context.theme.typography.body.sm),
                ),
            ],
          ),
        ),
      ],
    );
  }

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
      return FPopover(
        control: FPopoverControl.lifted(
          shown: active && preferences.modelsExpanded,
          onChange: preferences.setModelsExpanded,
        ),
        popoverAnchor: Alignment.topLeft,
        childAnchor: Alignment.topRight,
        popoverBuilder: (context, controller) => SizedBox(
          width: 260,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .6,
            ),
            child: _content(context, onSelected: controller.hide),
          ),
        ),
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
        SidebarDisclosure(
          navigation: navigation,
          label: '模型',
          expanded: preferences.modelsExpanded,
          showToggle: active,
          onToggle: () =>
              preferences.setModelsExpanded(!preferences.modelsExpanded),
        ),
        if (active && preferences.modelsExpanded)
          Flexible(
            child: Container(
              margin: const EdgeInsets.only(left: 16, top: 4, bottom: 4),
              padding: const EdgeInsets.only(left: 8),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: context.theme.colors.border),
                ),
              ),
              child: _content(context),
            ),
          ),
      ],
    );
  }
}
