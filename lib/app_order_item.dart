import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'app_navigation_item.dart' show ManagedAppIcon;
import 'managed_app.dart';

/// Sorting has no navigation action and starts from anywhere on the row.
class AppOrderItem extends StatefulWidget {
  const AppOrderItem({
    super.key,
    required this.app,
    required this.index,
    required this.onMove,
  });
  final ManagedApp app;
  final int index;
  final ValueChanged<int> onMove;

  @override
  State<AppOrderItem> createState() => _AppOrderItemState();
}

class _AppOrderItemState extends State<AppOrderItem> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => ReorderableDragStartListener(
    key: ValueKey('drag-${widget.app.name}'),
    index: widget.index,
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () =>
            widget.onMove(-1),
        const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () =>
            widget.onMove(1),
      },
      child: Focus(
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: Semantics(
            customSemanticsActions: {
              const CustomSemanticsAction(label: '向上移动应用'): () =>
                  widget.onMove(-1),
              const CustomSemanticsAction(label: '向下移动应用'): () =>
                  widget.onMove(1),
            },
            child: FFocusedOutline(
              focused: _focused,
              child: FItem(
                key: ValueKey('app-${widget.app.name}'),
                prefix: ManagedAppIcon(app: widget.app),
                title: Text(widget.app.label),
                suffix: const Icon(FLucideIcons.gripVertical, size: 16),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
