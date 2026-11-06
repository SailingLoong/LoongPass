import 'package:flutter/material.dart';
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
  });
  final ManagedApp app;
  final int index;
  final bool compact, selected;
  final VoidCallback? onPressed;
  final ValueChanged<int> onMove;
  @override
  State<AppNavigationItem> createState() => AppNavigationItemState();
}

class AppNavigationItemState extends State<AppNavigationItem> {
  bool _hovered = false, _focused = false;
  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    Widget icon = ExcludeSemantics(
      child: SizedBox(
        width: 28,
        height: 30,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: app.color,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text(
                app.monogram,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (widget.compact)
              Positioned(
                right: -3,
                bottom: -2,
                child: Container(
                  key: ValueKey('region-${app.name}'),
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    app.regionCode,
                    style: const TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (widget.compact)
      icon = ReorderableDelayedDragStartListener(
        key: ValueKey('drag-${app.name}'),
        index: widget.index,
        child: icon,
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
              child: SidebarNavigationButton(
                key: ValueKey('app-${app.name}'),
                label: app.label,
                icon: icon,
                compact: widget.compact,
                selected: widget.selected,
                onPressed: widget.onPressed,
                trailing: widget.compact
                    ? null
                    : Opacity(
                        opacity: _hovered || _focused ? 1 : 0,
                        child: ReorderableDragStartListener(
                          key: ValueKey('drag-${app.name}'),
                          index: widget.index,
                          child: const Tooltip(
                            message: '拖动排序 · ⌥↑ / ⌥↓',
                            child: Icon(Icons.drag_indicator, size: 16),
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
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
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: const Size(40, 38),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 10,
            vertical: 4,
          ),
          foregroundColor: selected ? colors.primary : colors.onSurfaceVariant,
          backgroundColor: selected
              ? colors.primaryContainer
              : Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        child: Row(
          mainAxisAlignment: compact
              ? MainAxisAlignment.center
              : MainAxisAlignment.start,
          children: [
            icon,
            if (!compact) ...[
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (trailing != null) trailing!,
            ],
            if (compact)
              Semantics(label: label, child: const SizedBox.shrink()),
          ],
        ),
      ),
    );
  }
}
