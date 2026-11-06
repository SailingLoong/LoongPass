import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/main.dart';
import '../lib/account_panel_header.dart';
import '../lib/workspace_tools.dart';
import '../lib/ui_preferences.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('desktop controls share the body scale in $brightness', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: loongPassTheme(brightness),
          home: Scaffold(
            body: Column(
              children: [
                ListTile(
                  title: const Text('账号标题'),
                  subtitle: const Text('账号说明'),
                  onTap: () {},
                ),
                DropdownButton<int>(
                  value: 1,
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('列表选项')),
                  ],
                  onChanged: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
      for (final label in ['账号标题', '列表选项']) {
        final style = DefaultTextStyle.of(
          tester.element(find.text(label).first),
        ).style;
        expect(style.fontSize, 13, reason: label);
        expect(style.letterSpacing, 0, reason: label);
        expect(
          style.fontFamily,
          Theme.of(
            tester.element(find.text(label).first),
          ).textTheme.bodyLarge!.fontFamily,
          reason: '$label keeps the platform font',
        );
      }
      expect(
        DefaultTextStyle.of(tester.element(find.text('账号说明'))).style.fontSize,
        12,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('toolbar keeps title metadata and actions in separate groups', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: loongPassTheme(Brightness.light),
        home: Scaffold(
          body: AccountPanelToolbar(
            title: 'WorkBuddy',
            accountCount: 2,
            helpText: '账号说明',
            actions: [
              FilledButton(onPressed: () {}, child: const Text('添加账号')),
              TextButton(onPressed: () {}, child: const Text('恢复已保存账号')),
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
    expect(find.byTooltip('使用说明'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings align each preference and fit a narrow viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(416, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preferences = UiPreferences();
    addTearDown(preferences.dispose);
    await tester.pumpWidget(
      MaterialApp(
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
  });

  testWidgets('settings selectors keep enlarged labels on one line', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(416, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preferences = UiPreferences();
    addTearDown(preferences.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: loongPassTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(body: WorkspaceSettingsPage(preferences: preferences)),
      ),
    );
    final label = tester.renderObject<RenderParagraph>(find.text('跟随系统').first);
    expect(
      label.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 4),
      ),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });
}
