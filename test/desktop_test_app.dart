import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/app_theme.dart';

/// Standalone component tests use the same theme and locale as the application.
class DesktopTestApp extends StatelessWidget {
  const DesktopTestApp({
    super.key,
    required this.home,
    this.theme,
    this.builder,
  });

  final Widget home;
  final ThemeData? theme;
  final TransitionBuilder? builder;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme ?? loongPassTheme(Brightness.light),
    locale: const Locale('zh', 'CN'),
    localizationsDelegates: FLocalizations.localizationsDelegates,
    supportedLocales: FLocalizations.supportedLocales,
    builder: (context, child) =>
        loongPassThemeBuilder(context, builder?.call(context, child) ?? child),
    home: home,
  );
}

Finder findTooltip(String message) => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.tooltip == message,
  description: 'Forui tooltip "$message"',
);

void testDesktopWidgets(
  String description,
  WidgetTesterCallback callback, {
  TestVariant<Object?> variant = const DefaultTestVariant(),
}) {
  testWidgets(description, (tester) async {
    try {
      await callback(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      // Forui's guarded press and tooltip futures outlive disposed widgets.
      // Finish their finite delays inside the test's fake clock before invariants.
      await tester.pump(const Duration(seconds: 1));
    }
  }, variant: variant);
}
