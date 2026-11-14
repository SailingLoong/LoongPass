import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/select_field_semantics.dart';
import 'desktop_test_app.dart';

void main() {
  testDesktopWidgets(
    'select retains keyboard focus and selection',
    (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      String? selected;
      await tester.pumpWidget(
        DesktopTestApp(
          home: Scaffold(
            body: FSelect<String>(
              builder: selectFieldSemantics,
              autoHide: true,
              focusNode: focus,
              items: const {'WorkBuddy 国内版': 'workbuddy', 'ZCode': 'zcode'},
              control: FSelectControl.managed(
                onChange: (value) => selected = value,
              ),
            ),
          ),
        ),
      );
      focus.requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selected, 'workbuddy');
      expect(focus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testDesktopWidgets('disabled select has no accessibility activation', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        DesktopTestApp(
          home: Scaffold(
            body: FSelect<String>(
              key: const Key('disabled-select'),
              builder: selectFieldSemantics,
              enabled: false,
              items: const {'WorkBuddy 国内版': 'workbuddy'},
              control: FSelectControl.lifted(
                value: 'workbuddy',
                onChange: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final data = tester
          .getSemantics(find.byKey(const Key('disabled-select')))
          .getSemanticsData();
      expect(data.label, contains('WorkBuddy 国内版'));
      expect(data.flagsCollection.isTextField, isFalse);
      expect(data.flagsCollection.isButton, isTrue);
      expect(data.flagsCollection.isEnabled, Tristate.isFalse);
      expect(data.flagsCollection.isFocused, Tristate.none);
      expect(data.hasAction(SemanticsAction.tap), isFalse);
    } finally {
      handle.dispose();
    }
  });
}
