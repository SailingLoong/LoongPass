import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

@immutable
class DesktopPalette {
  const DesktopPalette._({
    required this.brand,
    required this.brandForeground,
    required this.selected,
    required this.selectedForeground,
    required this.sidebar,
    required this.warning,
    required this.warningSurface,
  });

  final Color brand, brandForeground, selected, selectedForeground, sidebar;
  final Color warning, warningSurface;

  static DesktopPalette of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  static const light = DesktopPalette._(
    brand: Color(0xff2658d9),
    brandForeground: Color(0xffffffff),
    selected: Color(0xffe9efff),
    selectedForeground: Color(0xff244eb7),
    sidebar: Color(0xfff5f6f8),
    warning: Color(0xff845400),
    warningSurface: Color(0xfffcf3df),
  );
  static const dark = DesktopPalette._(
    brand: Color(0xff86a9ff),
    brandForeground: Color(0xff111214),
    selected: Color(0xff252e45),
    selectedForeground: Color(0xffb0c6ff),
    sidebar: Color(0xff191a1d),
    warning: Color(0xffedc77b),
    warningSurface: Color(0xff352d1e),
  );
}

extension DesktopDesign on BuildContext {
  DesktopPalette get desktopPalette =>
      DesktopPalette.of(theme.colors.brightness);

  double get desktopGutter {
    final width = MediaQuery.sizeOf(this).width;
    return width <= 410
        ? 14
        : width <= 864
        ? 19
        : (width * .03).clamp(18.0, 46.0);
  }

  TextStyle get desktopPageTitle => theme.typography.display.xl3.copyWith(
    color: theme.colors.foreground,
    fontWeight: FontWeight.w600,
    height: 1.25,
  );

  FTabsStyleDelta get desktopTabStyle => FTabsStyleDelta.delta(
    decoration: DecorationDelta.value(
      BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.colors.border)),
      ),
    ),
    indicatorDecoration: DecorationDelta.value(
      BoxDecoration(
        border: Border(
          bottom: BorderSide(color: desktopPalette.brand, width: 2),
        ),
      ),
    ),
    padding: const EdgeInsetsGeometryDelta.value(EdgeInsets.zero),
    indicatorSize: FTabBarIndicatorSize.label,
    spacing: 18,
  );
}
