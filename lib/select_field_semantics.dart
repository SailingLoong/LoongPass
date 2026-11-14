import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart' show TextField;

/// Keep Forui's field, focus and popover behavior while exposing a selector.
/// Flutter's macOS bridge can send `startEditing` to a read-only text node
/// when its value changes. A non-editable select is an expandable button.
Widget selectFieldSemantics(
  BuildContext context,
  FSelectStyle style,
  Set<FTextFieldVariant> variants,
  Widget child,
) {
  final field = child as TextField;
  return ListenableBuilder(
    listenable: Listenable.merge([field.controller, field.focusNode]),
    builder: (context, _) {
      final value = field.controller?.text ?? '';
      final enabled = field.enabled ?? true;
      final focusable = enabled && field.canRequestFocus;
      final desktopFocus = focusable && context.platformVariant.desktop;
      void requestFocus() {
        final focus = field.focusNode;
        if (focus != null && focus.canRequestFocus && !focus.hasFocus) {
          focus.requestFocus();
        }
      }

      return Semantics(
        button: true,
        enabled: enabled,
        focusable: focusable,
        focused: focusable ? field.focusNode?.hasFocus ?? false : null,
        label: value.isEmpty ? field.decoration?.hintText ?? '' : value,
        onTap: enabled ? field.onTap : null,
        onFocus: focusable ? requestFocus : null,
        onDidGainAccessibilityFocus: desktopFocus ? requestFocus : null,
        onDidLoseAccessibilityFocus: desktopFocus
            ? () => field.focusNode?.unfocus()
            : null,
        child: ExcludeSemantics(child: child),
      );
    },
  );
}
