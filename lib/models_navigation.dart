import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'app_navigation_item.dart';
import 'ui_preferences.dart';

/// Model identity and order come from the model service. This widget owns
/// search and navigation state only.
class ModelsNavigation extends StatefulWidget {
  const ModelsNavigation({
    super.key,
    required this.preferences,
    required this.compact,
    required this.active,
    required this.modelIds,
    required this.selectedModelId,
    required this.onOpen,
    required this.onSelectModel,
    this.searchTerms = const {},
  });

  final UiPreferences preferences;
  final bool compact, active;
  final List<String> modelIds;
  final Map<String, String> searchTerms;
  final String? selectedModelId;
  final VoidCallback onOpen;
  final ValueChanged<String> onSelectModel;

  @override
  State<ModelsNavigation> createState() => _ModelsNavigationState();
}

class _ModelsNavigationState extends State<ModelsNavigation> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Widget _content({VoidCallback? onSelected}) {
    final query = _search.text.trim().toLowerCase();
    final visible = widget.modelIds
        .where(
          (id) =>
              id == 'auto' ||
              (widget.searchTerms[id] ?? id).toLowerCase().contains(query),
        )
        .toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.modelIds.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: FTextField(
              key: const Key('model-nav-search'),
              hint: '筛选模型',
              size: FTextFieldSizeVariant.sm,
              prefixBuilder: (context, style, variants) =>
                  const Icon(FLucideIcons.search, size: 14),
              control: FTextFieldControl.managed(
                controller: _search,
                onChange: (_) => setState(() {}),
              ),
            ),
          ),
        Flexible(
          child: ListView(
            key: const PageStorageKey('model-list'),
            primary: false,
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              for (final id in visible)
                SidebarNavigationButton(
                  key: ValueKey('model-nav-$id'),
                  label: id == 'auto' ? 'LoongPass Auto' : id,
                  icon: const Icon(FLucideIcons.dot, size: 16),
                  compact: false,
                  nested: true,
                  maxLines: 2,
                  selected: widget.active && id == widget.selectedModelId,
                  onPressed: () {
                    widget.onSelectModel(id);
                    onSelected?.call();
                  },
                ),
              if (visible.isEmpty ||
                  (query.isNotEmpty && !visible.any((id) => id != 'auto')))
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    widget.modelIds.isEmpty ? '暂无模型' : '暂无匹配模型',
                    style: context.theme.typography.body.sm,
                  ),
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
      compact: widget.compact,
      selected: widget.active,
      onPressed: widget.onOpen,
    );
    if (widget.compact) {
      return FPopover(
        control: FPopoverControl.lifted(
          shown: widget.active && widget.preferences.modelsExpanded,
          onChange: widget.preferences.setModelsExpanded,
        ),
        popoverAnchor: Alignment.topLeft,
        childAnchor: Alignment.topRight,
        popoverBuilder: (context, controller) => SizedBox(
          width: 260,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .6,
            ),
            child: _content(onSelected: controller.hide),
          ),
        ),
        builder: (context, controller, _) => Semantics(
          expanded: widget.active && widget.preferences.modelsExpanded,
          child: navigation,
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          expanded: widget.active && widget.preferences.modelsExpanded,
          child: navigation,
        ),
        if (widget.active && widget.preferences.modelsExpanded)
          Flexible(
            child: Container(
              margin: const EdgeInsets.only(left: 16, top: 4, bottom: 4),
              padding: const EdgeInsets.only(left: 8),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: context.theme.colors.border),
                ),
              ),
              child: _content(),
            ),
          ),
      ],
    );
  }
}
