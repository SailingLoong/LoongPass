import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart' show Theme, ThemeData;

/// Forui owns all desktop colors, typography and component styles.
FThemeData loongPassDesignTheme(Brightness brightness) =>
    brightness == Brightness.dark
    ? FTheme.neutral.dark.desktop
    : FTheme.neutral.light.desktop;

/// MaterialApp hosts navigation and the persisted ThemeMode preference.
ThemeData loongPassTheme(Brightness brightness) =>
    loongPassDesignTheme(brightness).toApproximateMaterialTheme();

Widget loongPassThemeBuilder(BuildContext context, Widget? child) => FTheme(
  data: loongPassDesignTheme(Theme.of(context).brightness),
  child: child!,
);
