import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart' show Theme, ThemeData;

/// Forui supplies desktop tokens and component styles with explicit app fonts.
FThemeData loongPassDesignTheme(Brightness brightness) {
  final base = brightness == Brightness.dark
      ? FTheme.neutral.dark.desktop
      : FTheme.neutral.light.desktop;
  final typeface = FTypeface.inherit(
    colors: base.colors,
    touch: false,
    fontFamily: FTypeface.defaultFontFamily,
    fontFamilyFallback: const ['SourceHanSansSC'],
  );
  // Rebuild global and component styles from the typography, as required by
  // Forui's theme contract. Retained styles would keep old form-field fonts.
  final theme = FThemeData(
    colors: base.colors,
    touch: false,
    typography: FTypography(display: typeface, body: typeface),
  );
  return theme.copyWith(
    accordionStyle: const FAccordionStyleDelta.delta(
      titlePadding: EdgeInsetsGeometryDelta.value(
        EdgeInsets.symmetric(vertical: 10),
      ),
      childPadding: EdgeInsetsGeometryDelta.value(EdgeInsets.only(bottom: 12)),
    ),
  );
}

/// MaterialApp hosts navigation and the persisted ThemeMode preference.
ThemeData loongPassTheme(Brightness brightness) =>
    loongPassDesignTheme(brightness).toApproximateMaterialTheme();

Widget loongPassThemeBuilder(BuildContext context, Widget? child) => FTheme(
  data: loongPassDesignTheme(Theme.of(context).brightness),
  child: child!,
);
