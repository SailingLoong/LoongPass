import 'package:flutter/material.dart';

/// Shared desktop typography and controls. ThemeData keeps the platform's
/// system font and fallback, including SF and Chinese glyphs on macOS.
ThemeData loongPassTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final colors =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF3566C8),
        brightness: brightness,
      ).copyWith(
        primary: dark ? const Color(0xFF9DBBFF) : const Color(0xFF3566C8),
        onPrimary: dark ? const Color(0xFF142B56) : Colors.white,
        primaryContainer: dark
            ? const Color(0xFF253654)
            : const Color(0xFFE8EFFC),
        onPrimaryContainer: dark
            ? const Color(0xFFC8DAFF)
            : const Color(0xFF2854AA),
        surface: dark ? const Color(0xFF191C22) : const Color(0xFFFAFBFC),
        onSurface: dark ? const Color(0xFFE7EAF0) : const Color(0xFF20252D),
        onSurfaceVariant: dark
            ? const Color(0xFFA3ABB8)
            : const Color(0xFF69717E),
        surfaceContainerLowest: dark ? const Color(0xFF20242C) : Colors.white,
        surfaceContainerLow: dark
            ? const Color(0xFF16191F)
            : const Color(0xFFF3F5F7),
        surfaceContainer: dark
            ? const Color(0xFF252A33)
            : const Color(0xFFF0F2F5),
        surfaceContainerHigh: dark
            ? const Color(0xFF2B313C)
            : const Color(0xFFEAEDF1),
        surfaceContainerHighest: dark
            ? const Color(0xFF343C49)
            : const Color(0xFFE4E8EE),
        outline: dark ? const Color(0xFF606B7C) : const Color(0xFFB8C0CC),
        outlineVariant: dark
            ? const Color(0xFF323945)
            : const Color(0xFFE6E9EE),
        surfaceTint: Colors.transparent,
      );
  final desktopText = const TextTheme(
    displayLarge: TextStyle(
      fontSize: 32,
      fontWeight: FontWeight.w600,
      letterSpacing: -.5,
    ),
    displayMedium: TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w600,
      letterSpacing: -.4,
    ),
    displaySmall: TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w600,
      letterSpacing: -.3,
    ),
    headlineLarge: TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w600,
      letterSpacing: -.3,
    ),
    headlineMedium: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w600,
      letterSpacing: -.3,
    ),
    headlineSmall: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      letterSpacing: -.2,
    ),
    titleLarge: TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
      height: 1.4,
    ),
    titleMedium: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
      height: 1.4,
    ),
    titleSmall: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
      height: 1.4,
    ),
    bodyLarge: TextStyle(fontSize: 13, letterSpacing: 0, height: 1.5),
    bodyMedium: TextStyle(fontSize: 13, letterSpacing: 0, height: 1.5),
    bodySmall: TextStyle(fontSize: 11, letterSpacing: 0, height: 1.5),
    labelLarge: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
      height: 1.3,
    ),
    labelMedium: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
      height: 1.3,
    ),
    labelSmall: TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
      height: 1.3,
    ),
  ).apply(bodyColor: colors.onSurface, displayColor: colors.onSurface);
  final theme = ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    scaffoldBackgroundColor: colors.surface,
    visualDensity: VisualDensity.compact,
    textTheme: desktopText,
  );
  // Component styles must use the merged theme so they retain system fonts.
  final text = theme.textTheme;
  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(6),
  );
  return theme.copyWith(
    dividerTheme: DividerThemeData(
      color: colors.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    listTileTheme: ListTileThemeData(
      titleTextStyle: text.bodyLarge,
      subtitleTextStyle: text.bodyLarge!.copyWith(
        fontSize: 12,
        color: colors.onSurfaceVariant,
      ),
      iconColor: colors.onSurfaceVariant,
      minVerticalPadding: 8,
      minTileHeight: 48,
      horizontalTitleGap: 10,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: colors.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors.outlineVariant),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surfaceContainerLowest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceContainerLowest,
      isDense: true,
      hintStyle: text.bodyLarge!.copyWith(color: colors.onSurfaceVariant),
      prefixIconColor: colors.onSurfaceVariant,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: colors.primary, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        elevation: 0,
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: buttonShape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.onSurface,
        side: BorderSide(color: colors.outlineVariant),
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        shape: buttonShape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        shape: buttonShape,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: colors.onSurfaceVariant,
        minimumSize: const Size(30, 30),
        padding: const EdgeInsets.all(5),
        shape: buttonShape,
      ),
    ),
    chipTheme: ChipThemeData(
      labelStyle: text.labelLarge,
      backgroundColor: colors.surfaceContainerLowest,
      selectedColor: colors.primaryContainer,
      side: BorderSide(color: colors.outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      padding: const EdgeInsets.symmetric(horizontal: 4),
    ),
  );
}
