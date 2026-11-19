import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;

import '../lib/app_updates.dart';
import '../lib/ui_preferences.dart';
import '../lib/workspace_tools.dart';
import 'desktop_test_app.dart';

void main() {
  testDesktopWidgets('the update shortcut selects its topic without checking', (
    tester,
  ) async {
    final section = ValueNotifier(SettingsSection.appearance);
    final preferences = UiPreferences();
    final updates = AppUpdates();
    addTearDown(section.dispose);
    addTearDown(preferences.dispose);
    addTearDown(updates.dispose);
    await tester.pumpWidget(
      DesktopTestApp(
        home: FScaffold(
          child: WorkspaceSettingsPage(
            preferences: preferences,
            updates: updates,
            section: section,
          ),
        ),
      ),
    );
    expect(find.text('检查更新'), findsNothing);
    section.value = SettingsSection.updates;
    await tester.pumpAndSettle();
    expect(find.text('检查更新').hitTestable(), findsOneWidget);
    expect(updates.lastCheckAt, isNull);
    await tester.tap(find.byKey(const ValueKey(SettingsSection.appearance)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色').hitTestable());
    await tester.pumpAndSettle();
    expect(preferences.themeMode, ThemeMode.dark);
    expect(section.value, SettingsSection.appearance);
  });
}
