import 'package:flutter/rendering.dart';

import '../lib/compact_accounts_table.dart';
import 'desktop_test_app.dart';

import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/main.dart';
import '../lib/workspace_tools.dart';
import '../lib/ui_preferences.dart';

void main() {
  for (final brightness in Brightness.values) {
    testDesktopWidgets(
      'desktop controls use the official Forui typography in $brightness',
      (tester) async {
        await tester.pumpWidget(
          DesktopTestApp(
            theme: loongPassTheme(brightness),
            home: Scaffold(
              body: Column(
                children: [
                  FItem(
                    title: const Text('账号标题'),
                    subtitle: const Text('账号说明'),
                    onPress: () {},
                  ),
                  FSelect<int>(
                    items: {'列表选项': 1},
                    control: FSelectControl.managed(initial: 1),
                  ),
                  const FTextField(
                    label: Text('字段标签'),
                    description: Text('字段说明'),
                  ),
                  const FTextField(error: Text('字段错误')),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final reference = loongPassDesignTheme(brightness).typography;
        final styles = [
          DefaultTextStyle.of(tester.element(find.text('账号标题'))).style,
          tester.widget<EditableText>(find.byType(EditableText).first).style,
        ];
        for (final style in styles) {
          expect(style.fontSize, reference.body.sm.fontSize);
          expect(style.fontFamily, reference.body.sm.fontFamily);
          expect(style.fontFamily, FTypeface.defaultFontFamily);
          expect(style.fontFamilyFallback, ['SourceHanSansSC']);
          expect(style.letterSpacing, reference.body.sm.letterSpacing);
        }
        expect(
          DefaultTextStyle.of(tester.element(find.text('账号说明'))).style.fontSize,
          reference.body.xs.fontSize,
        );
        for (final label in ['字段标签', '字段说明', '字段错误']) {
          final style = DefaultTextStyle.of(tester.element(find.text(label)))
              .style;
          expect(style.fontFamily, FTypeface.defaultFontFamily);
          expect(style.fontFamilyFallback, ['SourceHanSansSC']);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testDesktopWidgets(
    'toolbar keeps title metadata and actions in separate groups',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        DesktopTestApp(
          theme: loongPassTheme(Brightness.light),
          home: Scaffold(
            body: AccountPanelToolbar(
              title: 'WorkBuddy',
              accountCount: 2,
              helpText: '账号说明',
              actions: [
                FButton(
                  mainAxisSize: MainAxisSize.min,
                  size: FButtonSizeVariant.sm,
                  onPress: () {},
                  child: const Text('添加账号'),
                ),
                FButton(
                  mainAxisSize: MainAxisSize.min,
                  size: FButtonSizeVariant.sm,
                  onPress: () {},
                  child: const Text('恢复已保存账号'),
                ),
              ],
            ),
          ),
        ),
      );
      expect(
        tester.getTopLeft(find.text('2 个账号')).dy,
        greaterThan(tester.getBottomLeft(find.text('WorkBuddy')).dy),
      );
      expect(tester.getTopLeft(find.text('添加账号')).dx, greaterThan(600));
      expect(findTooltip('使用说明'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testDesktopWidgets(
    'settings align each preference and fit a narrow viewport',
    (tester) async {
      tester.view.physicalSize = const Size(416, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final preferences = UiPreferences();
      addTearDown(preferences.dispose);
      await tester.pumpWidget(
        DesktopTestApp(
          theme: loongPassTheme(Brightness.light),
          home: Scaffold(body: WorkspaceSettingsPage(preferences: preferences)),
        ),
      );
      expect(
        tester.getTopLeft(find.text('账号行距')).dy,
        greaterThan(tester.getBottomLeft(find.text('主题')).dy),
      );
      await tester.tap(find.text('紧凑'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('舒适').last);
      await tester.pumpAndSettle();
      expect(preferences.comfortable, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testDesktopWidgets('settings selectors keep enlarged labels on one line', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(416, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preferences = UiPreferences();
    addTearDown(preferences.dispose);
    await tester.pumpWidget(
      DesktopTestApp(
        theme: loongPassTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(body: WorkspaceSettingsPage(preferences: preferences)),
      ),
    );
    final label = tester
        .state<EditableTextState>(
          find.descendant(
            of: find.byKey(const Key('appearance-theme')),
            matching: find.byType(EditableText),
          ),
        )
        .renderEditable;
    expect(
      label.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 4),
      ),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });
  testDesktopWidgets(
    'comfortable density adds space to the two-line account rows',
    (tester) async {
      final preferences = UiPreferences();
      addTearDown(preferences.dispose);
      await tester.pumpWidget(
        UiPreferencesScope(
          preferences: preferences,
          child: DesktopTestApp(
            home: const Scaffold(
              body: CompactAccountsTable(
                entries: [
                  AccountTableEntry(
                    id: 'density',
                    label: 'Account',
                    identity: 'synthetic',
                    balance: '100 credits',
                    status: 'saved',
                    details: Text('Details'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final label = find.byKey(const ValueKey('account-density'));
      final row = find.ancestor(of: label, matching: find.byType(Row)).first;
      final compactHeight = tester.getSize(row).height;
      preferences.setComfortable(true);
      await tester.pumpAndSettle();
      expect(tester.getSize(row).height, greaterThan(compactHeight));
      expect(tester.takeException(), isNull);
    },
  );
  testDesktopWidgets(
    'account rows and search keep enlarged text vertically visible',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        DesktopTestApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: CompactAccountsTable(
                entries: [
                  AccountTableEntry(
                    id: 'large',
                    label: 'Large account',
                    identity: 'synthetic',
                    balance: '1000 积分',
                    status: '已保存',
                    details: Text('账号详情'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('account-search')), 'Large');
      await tester.pumpAndSettle();
      final editable = tester
          .state<EditableTextState>(
            find.descendant(
              of: find.byKey(const Key('account-search')),
              matching: find.byType(EditableText),
            ),
          )
          .renderEditable;
      expect(
        editable.size.height,
        greaterThanOrEqualTo(editable.preferredLineHeight),
      );
      final label = tester.renderObject<RenderParagraph>(
        find.text('Large account'),
      );
      final boxes = label.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 13),
      );
      expect(boxes, hasLength(1));
      expect(label.size.height, greaterThanOrEqualTo(boxes.single.bottom));
      expect(tester.takeException(), isNull);
    },
  );
}
