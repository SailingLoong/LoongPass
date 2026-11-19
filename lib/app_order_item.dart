import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'app_navigation_item.dart' show ManagedAppIcon;
import 'managed_app.dart';

class AppOrderItem extends StatefulWidget {
  const AppOrderItem({
    super.key,
    required this.app,
    required this.index,
    required this.onMove,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.visible,
    required this.onShow,
  });
  final ManagedApp app;
  final int index;
  final ValueChanged<int> onMove;
  final bool canMoveUp, canMoveDown, visible;
  final ValueChanged<bool> onShow;

  @override
  State<AppOrderItem> createState() => _AppOrderItemState();
}

class _AppOrderItemState extends State<AppOrderItem> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: ReorderableDragStartListener(
          key: ValueKey('drag-${widget.app.name}'),
          index: widget.index,
          child: CallbackShortcuts(
            bindings: {
              if (widget.canMoveUp)
                const SingleActivator(
                  LogicalKeyboardKey.arrowUp,
                  alt: true,
                ): () =>
                    widget.onMove(-1),
              if (widget.canMoveDown)
                const SingleActivator(
                  LogicalKeyboardKey.arrowDown,
                  alt: true,
                ): () =>
                    widget.onMove(1),
            },
            child: Focus(
              onFocusChange: (focused) => setState(() => _focused = focused),
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: Semantics(
                  customSemanticsActions: {
                    if (widget.canMoveUp)
                      const CustomSemanticsAction(label: '向上移动应用'): () =>
                          widget.onMove(-1),
                    if (widget.canMoveDown)
                      const CustomSemanticsAction(label: '向下移动应用'): () =>
                          widget.onMove(1),
                  },
                  child: FFocusedOutline(
                    focused: _focused,
                    child: FItem(
                      key: ValueKey('app-${widget.app.name}'),
                      prefix: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(FLucideIcons.gripVertical, size: 14),
                          const SizedBox(width: 6),
                          ManagedAppIcon(app: widget.app),
                        ],
                      ),
                      title: Text(widget.app.label),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      FButton.icon(
        variant: FButtonVariant.ghost,
        size: FButtonSizeVariant.sm,
        semanticsLabel: '上移 ${widget.app.label}',
        onPress: widget.canMoveUp ? () => widget.onMove(-1) : null,
        child: const Icon(FLucideIcons.arrowUp, size: 14),
      ),
      FButton.icon(
        variant: FButtonVariant.ghost,
        size: FButtonSizeVariant.sm,
        semanticsLabel: '下移 ${widget.app.label}',
        onPress: widget.canMoveDown ? () => widget.onMove(1) : null,
        child: const Icon(FLucideIcons.arrowDown, size: 14),
      ),
      const SizedBox(width: 8),
      FSwitch(
        semanticsLabel: '在侧栏显示 ${widget.app.label}',
        value: widget.visible,
        onChange: widget.onShow,
      ),
    ],
  );
}
