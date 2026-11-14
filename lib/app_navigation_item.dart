import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';

import 'managed_app.dart';

class AppNavigationItem extends StatefulWidget {
  const AppNavigationItem({
    super.key,
    required this.app,
    required this.index,
    required this.compact,
    required this.selected,
    required this.onPressed,
    required this.onMove,
    this.onHide,
  });
  final ManagedApp app;
  final int index;
  final bool compact, selected;
  final VoidCallback? onPressed;
  final ValueChanged<int> onMove;
  final VoidCallback? onHide;
  @override
  State<AppNavigationItem> createState() => AppNavigationItemState();
}

class AppNavigationItemState extends State<AppNavigationItem> {
  bool _hovered = false, _focused = false;
  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    Widget icon = ManagedAppIcon(app: app);
    if (widget.onHide != null)
      icon = ReorderableDragStartListener(
        key: ValueKey('drag-${app.name}'),
        index: widget.index,
        child: MouseRegion(cursor: SystemMouseCursors.grab, child: icon),
      );
    else if (widget.compact)
      icon = ReorderableDelayedDragStartListener(
        key: ValueKey('drag-${app.name}'),
        index: widget.index,
        child: MouseRegion(cursor: SystemMouseCursors.grab, child: icon),
      );
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () =>
                widget.onMove(-1),
            const SingleActivator(
              LogicalKeyboardKey.arrowDown,
              alt: true,
            ): () =>
                widget.onMove(1),
          },
          child: Focus(
            onFocusChange: (v) => setState(() => _focused = v),
            child: Semantics(
              key: ValueKey('selected-${app.name}'),
              selected: widget.selected,
              customSemanticsActions: {
                const CustomSemanticsAction(label: '向上移动应用'): () =>
                    widget.onMove(-1),
                const CustomSemanticsAction(label: '向下移动应用'): () =>
                    widget.onMove(1),
              },
              child: Stack(
                children: [
                  Padding(
                    padding: EdgeInsets.only(
                      right: widget.onHide != null && !widget.compact ? 24 : 0,
                    ),
                    child: SidebarNavigationButton(
                      key: ValueKey('app-${app.name}'),
                      label: app.label,
                      icon: icon,
                      compact: widget.compact,
                      selected: widget.selected,
                      onPressed: widget.onPressed,
                      trailing: widget.compact || widget.onHide != null
                          ? null
                          : Opacity(
                              opacity: _hovered || _focused ? 1 : 0,
                              child: ReorderableDragStartListener(
                                key: ValueKey('drag-${app.name}'),
                                index: widget.index,
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.grab,
                                  child: Semantics(
                                    label: '拖动排序 · Option + ↑ / ↓',
                                    child: Icon(
                                      FLucideIcons.gripVertical,
                                      size: 16,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ),
                  if (widget.onHide != null)
                    Positioned(
                      right: 0,
                      top: widget.compact ? 0 : 4,
                      child: Opacity(
                        opacity: _hovered || _focused ? 1 : 0,
                        child: FTooltip(
                          tipBuilder: (context, controller) =>
                              Text('隐藏 ${app.label}'),
                          child: SizedBox.square(
                            dimension: widget.compact ? 18 : 24,
                            child: FButton.icon(
                              key: ValueKey('hide-${app.name}'),
                              variant: FButtonVariant.ghost,
                              size: FButtonSizeVariant.sm,
                              style: const FButtonStyleDelta.delta(
                                iconContentStyle:
                                    FButtonIconContentStyleDelta.delta(
                                      padding: EdgeInsetsGeometryDelta.value(
                                        EdgeInsets.all(4),
                                      ),
                                    ),
                              ),
                              semanticsLabel: '隐藏 ${app.label}',
                              onPress: widget.onHide,
                              child: const Icon(FLucideIcons.x, size: 12),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ManagedAppIcon extends StatelessWidget {
  const ManagedAppIcon({super.key, required this.app});
  final ManagedApp app;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: 20,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Image.asset(
            app.iconAsset,
            width: 20,
            height: 20,
            fit: BoxFit.contain,
          ),
          if (app.regionCode == 'CN')
            Positioned(
              right: 0,
              bottom: 0,
              child: Transform.scale(
                key: ValueKey('region-${app.name}'),
                scale: .55,
                alignment: Alignment.bottomRight,
                child: FBadge(
                  variant: FBadgeVariant.secondary,
                  child: Text(app.regionCode),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class SidebarNavigationButton extends StatelessWidget {
  const SidebarNavigationButton({
    super.key,
    required this.label,
    required this.icon,
    required this.compact,
    required this.selected,
    required this.onPressed,
    this.trailing,
  });
  final String label;
  final Widget icon;
  final bool compact, selected;
  final VoidCallback? onPressed;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final variant = selected ? FButtonVariant.secondary : FButtonVariant.ghost;
    final button = Semantics(
      tooltip: label,
      child: compact
          ? FButton.icon(
              variant: variant,
              size: FButtonSizeVariant.sm,
              selected: selected,
              semanticsLabel: label,
              onPress: onPressed,
              child: icon,
            )
          : FButton(
              variant: variant,
              size: FButtonSizeVariant.sm,
              selected: selected,
              onPress: onPressed,
              mainAxisSize: MainAxisSize.max,
              mainAxisAlignment: MainAxisAlignment.start,
              prefix: icon,
              suffix: trailing,
              child: Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
    );
    return compact
        ? FTooltip(
            tipBuilder: (context, controller) => Text(label),
            child: button,
          )
        : button;
  }
}
