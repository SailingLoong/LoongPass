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
    final actionsVisible = _hovered || _focused;
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
            canRequestFocus: false,
            onFocusChange: (v) => setState(() => _focused = v),
            child: Semantics(
              key: ValueKey('selected-${app.name}'),
              selected: widget.selected,
              customSemanticsActions: {
                const CustomSemanticsAction(label: '向上移动应用'): () =>
                    widget.onMove(-1),
                const CustomSemanticsAction(label: '向下移动应用'): () =>
                    widget.onMove(1),
                if (widget.onHide != null)
                  const CustomSemanticsAction(label: '隐藏应用'): widget.onHide!,
              },
              child: Stack(
                children: [
                  SidebarNavigationButton(
                    key: ValueKey('app-${app.name}'),
                    label: app.label,
                    tooltip: '${app.label} · ${app.region}',
                    icon: icon,
                    compact: widget.compact,
                    selected: widget.selected,
                    onPressed: widget.onPressed,
                    trailing: widget.compact || widget.onHide != null
                        ? null
                        : Opacity(
                            opacity: actionsVisible ? 1 : 0,
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
                  if (widget.onHide != null)
                    Positioned(
                      right: widget.compact ? 0 : 4,
                      top: widget.compact ? 0 : 6,
                      child: IgnorePointer(
                        ignoring: !actionsVisible,
                        child: Opacity(
                          opacity: actionsVisible ? 1 : 0,
                          child: FTooltip(
                            tipBuilder: (context, controller) =>
                                Text('隐藏 ${app.label}'),
                            child: SizedBox.square(
                              dimension: widget.compact ? 20 : 24,
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
              child: FBadge(
                key: ValueKey('region-${app.name}'),
                variant: FBadgeVariant.secondary,
                style: const FBadgeStyleDelta.delta(
                  padding: EdgeInsetsGeometryDelta.value(
                    EdgeInsets.symmetric(horizontal: 2),
                  ),
                  labelTextStyle: TextStyleDelta.delta(
                    fontSize: 7,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: Text(app.regionCode),
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
    this.tooltip,
  });
  final String label;
  final Widget icon;
  final bool compact, selected;
  final VoidCallback? onPressed;
  final Widget? trailing;
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final variant = selected ? FButtonVariant.secondary : FButtonVariant.ghost;
    final iconSlot = SizedBox.square(dimension: 20, child: Center(child: icon));
    final button = Semantics(
      tooltip: tooltip ?? label,
      child: compact
          ? FButton.icon(
              variant: variant,
              size: FButtonSizeVariant.md,
              style: const FButtonStyleDelta.delta(
                iconContentStyle: FButtonIconContentStyleDelta.delta(
                  padding: EdgeInsetsGeometryDelta.value(EdgeInsets.all(8)),
                ),
              ),
              selected: selected,
              semanticsLabel: label,
              onPress: onPressed,
              child: iconSlot,
            )
          : FButton(
              variant: variant,
              size: FButtonSizeVariant.md,
              style: const FButtonStyleDelta.delta(
                contentStyle: FButtonContentStyleDelta.delta(
                  padding: EdgeInsetsGeometryDelta.value(EdgeInsets.all(8)),
                  spacing: 8,
                ),
              ),
              selected: selected,
              onPress: onPressed,
              mainAxisSize: MainAxisSize.max,
              mainAxisAlignment: MainAxisAlignment.start,
              prefix: iconSlot,
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
    return SizedBox(
      width: double.infinity,
      child: compact
          ? FTooltip(
              tipBuilder: (context, controller) => Text(tooltip ?? label),
              child: button,
            )
          : button,
    );
  }
}
