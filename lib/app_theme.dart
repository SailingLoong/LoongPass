import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart' show Theme, ThemeData;

import 'desktop_theme.dart';

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
  final palette = DesktopPalette.of(brightness);
  return theme.copyWith(
    switchStyle: FSwitchStyleDelta.delta(
      trackColor: .delta([
        .exact({FSwitchVariant.selected}, palette.brand),
        .exact({
          FSwitchVariant.selected.and(FSwitchVariant.disabled),
        }, base.colors.disable(palette.brand)),
      ]),
      thumbColor: .delta([
        .exact({FSwitchVariant.selected}, palette.brandForeground),
      ]),
    ),
    accordionStyle: const FAccordionStyleDelta.delta(
      titlePadding: EdgeInsetsGeometryDelta.value(
        EdgeInsets.symmetric(vertical: 10),
      ),
      childPadding: EdgeInsetsGeometryDelta.value(EdgeInsets.only(bottom: 12)),
    ),
  );
}

/// MaterialApp hosts navigation and the persisted ThemeMode preference.
ThemeData loongPassTheme(Brightness brightness) {
  final theme = loongPassDesignTheme(brightness).toApproximateMaterialTheme();
  return theme.copyWith(
    tabBarTheme: theme.tabBarTheme.copyWith(
      labelPadding: const EdgeInsetsDirectional.only(end: 15),
    ),
  );
}

Widget loongPassThemeBuilder(BuildContext context, Widget? child) => FTheme(
  data: loongPassDesignTheme(Theme.of(context).brightness),
  child: child!,
);
