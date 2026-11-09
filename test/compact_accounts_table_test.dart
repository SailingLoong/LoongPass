import '../lib/app_theme.dart';
import 'desktop_test_app.dart';

import 'package:forui/forui.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

import '../lib/compact_accounts_table.dart';
import '../lib/credit_summary.dart';
import '../lib/ui_preferences.dart';

void main() {
  Future<void> expiryRows(WidgetTester tester, Brightness brightness) async {
    final now = DateTime.now();
    await tester.pumpWidget(
      DesktopTestApp(
        theme: loongPassTheme(brightness),
        home: Scaffold(
          body: CompactAccountsTable(
            entries: [
              for (final entry in {'near': 2, 'later': 14}.entries)
                AccountTableEntry(
                  id: entry.key,
                  label: entry.key,
                  identity: 'synthetic-${entry.key}',
                  balance: '1000 积分',
                  status: '已保存',
                  details: const Text('账号详情'),
                  credits: CreditSummary(1000, 0, now, [
                    CreditExpiry(now.add(Duration(days: entry.value)), 1000),
                  ]),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testDesktopWidgets(
    'balance and expiry cells retain visible hover and keyboard focus',
    (tester) async {
      await expiryRows(tester, Brightness.light);
      final balance = find.ancestor(
        of: find.text('1000 积分').first,
        matching: find.byType(FButton),
      );
      expect(balance, findsOneWidget);
      expect(
        tester.widget(find.byKey(const Key('expiry-near'))),
        isA<FButton>(),
      );
      List<Decoration> decorations() => tester
          .widgetList<DecoratedBox>(
            find.descendant(of: balance, matching: find.byType(DecoratedBox)),
          )
          .map((box) => box.decoration)
          .toList();
      final before = decorations();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(balance));
      await tester.pumpAndSettle();
      expect(decorations(), isNot(equals(before)));
      await mouse.moveTo(Offset.zero);
      await mouse.removePointer();
      await tester.pumpAndSettle();
      bool focused() => tester
          .widget<FFocusedOutline>(
            find
                .descendant(of: balance, matching: find.byType(FFocusedOutline))
                .first,
          )
          .focused;
      for (var index = 0; index < 16 && !focused(); index++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
      }
      expect(focused(), isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );

  testDesktopWidgets('near expiry retains its reminder color in both themes', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      await expiryRows(tester, brightness);
      Color? color(String id) => tester
          .widget<Text>(
            find
                .descendant(
                  of: find.byKey(ValueKey('expiry-$id')),
                  matching: find.byType(Text),
                )
                .first,
          )
          .style
          ?.color;
      final colors = loongPassDesignTheme(brightness).colors;
      expect(color('near'), colors.error);
      expect(color('later'), colors.foreground);
      expect(tester.takeException(), isNull);
    }
  });

  testDesktopWidgets(
    'favorites survive table recreation and unmatched search offers reset',
    (tester) async {
      final preferences = UiPreferences();
      addTearDown(preferences.dispose);
      Widget page() => UiPreferencesScope(
        preferences: preferences,
        child: DesktopTestApp(
          home: Scaffold(
            body: CompactAccountsTable(
              entries: const [
                AccountTableEntry(
                  id: 'saved',
                  label: 'Saved account',
                  identity: 'synthetic',
                  balance: '880 积分',
                  status: 'ready',
                  details: Text('Details'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpWidget(page());
      await tester.tap(findTooltip('设为常用'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(page());
      expect(
        tester
            .widget<FButton>(
              find.descendant(
                of: findTooltip('取消常用'),
                matching: find.byType(FButton),
              ),
            )
            .selected,
        isTrue,
      );
      await tester.tap(find.text('常用'));
      await tester.pumpAndSettle();
      expect(find.text('Saved account'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('account-search')),
        'no match',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('清除搜索和筛选'));
      await tester.pumpAndSettle();
      expect(find.text('Saved account'), findsOneWidget);
    },
  );
  testDesktopWidgets(
    'expired snapshot batches cannot hide the next future expiry from filtering',
    (tester) async {
      final now = DateTime.now();
      await tester.pumpWidget(
        DesktopTestApp(
          home: Scaffold(
            body: CompactAccountsTable(
              entries: [
                AccountTableEntry(
                  id: 'mixed',
                  label: 'Mixed batches',
                  identity: 'synthetic',
                  balance: '300 积分',
                  status: 'ready',
                  details: const Text('Details'),
                  credits: CreditSummary(
                    300,
                    0,
                    now.subtract(const Duration(days: 2)),
                    [
                      CreditExpiry(now.subtract(const Duration(days: 1)), 100),
                      CreditExpiry(now.add(const Duration(days: 1)), 200),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('7 天内到期'));
      await tester.pumpAndSettle();
      expect(find.text('Mixed batches'), findsOneWidget);
      expect(find.textContaining('200 积分'), findsOneWidget);
      expect(find.textContaining('100 积分'), findsNothing);
      await tester.tap(find.byKey(const Key('expiry-mixed')));
      await tester.pumpAndSettle();
      expect(find.textContaining('200 积分'), findsWidgets);
      expect(find.textContaining('100 积分'), findsNothing);
    },
  );
  testDesktopWidgets(
    'open details follows owner messages and values without reopening',
    (tester) async {
      final rows = ValueNotifier<List<AccountTableEntry>>([]);
      addTearDown(rows.dispose);
      AccountTableEntry row(String? notice) => AccountTableEntry(
        id: 'one',
        label: 'Test account',
        identity: 'synthetic',
        balance: '12 积分',
        status: 'ready',
        notice: notice,
        details: Text(notice == null ? '原明细' : '更新后的明细'),
      );
      rows.value = [row(null)];
      await tester.pumpWidget(
        DesktopTestApp(
          home: Scaffold(
            body: ValueListenableBuilder<List<AccountTableEntry>>(
              valueListenable: rows,
              builder: (context, value, _) =>
                  CompactAccountsTable(entries: value),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('account-one')));
      await tester.pumpAndSettle();
      rows.value = [row('查询失败，请重试')];
      await tester.pumpAndSettle();
      expect(find.text('查询失败，请重试'), findsOneWidget);
      expect(find.text('更新后的明细'), findsOneWidget);
      expect(find.text('原明细'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
    },
  );
  Future<void> mount(WidgetTester tester, {VoidCallback? activate}) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      DesktopTestApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CompactAccountsTable(
              entries: [
                for (var i = 1; i <= 20; i++)
                  AccountTableEntry(
                    id: '$i',
                    label: '账号 $i',
                    identity: 'user$i@example.test',
                    balance: '$i 积分',
                    status: '等待检查',
                    credits: i == 20
                        ? CreditSummary(880, 260, DateTime(2026, 11, 6), [
                            CreditExpiry(
                              DateTime.now().add(const Duration(days: 1)),
                              120,
                            ),
                            CreditExpiry(
                              DateTime.now().add(const Duration(days: 2)),
                              200,
                            ),
                            CreditExpiry(
                              DateTime.now().add(const Duration(days: 3)),
                              300,
                            ),
                          ])
                        : null,
                    onActivate: activate,
                    details: const Text('账号详情内容'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testDesktopWidgets(
    'keyboard users can reveal and activate the switch without a mouse',
    (tester) async {
      var switched = false;
      await mount(tester, activate: () => switched = true);
      final target = find.byKey(const Key('activate-1'));
      for (var i = 0; i < 20; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        if (Focus.of(tester.element(target)).hasFocus) break;
      }
      expect(
        tester
            .widget<Opacity>(
              find.ancestor(of: target, matching: find.byType(Opacity)).first,
            )
            .opacity,
        1,
      );
      // The first focus in this row is the favourite control; traverse to switch.
      for (var i = 0; i < 6 && !switched; i++) {
        final focus = FocusManager.instance.primaryFocus;
        if (focus?.context != null &&
            focus!.context!.findAncestorWidgetOfExactType<FButton>()?.key ==
                const Key('activate-1')) {
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        } else {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        }
        await tester.pump();
      }
      expect(switched, isTrue);
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );

  testDesktopWidgets(
    'narrow windows scroll the table and page-size changes reset to the first page',
    (tester) async {
      await mount(tester);
      await tester.tap(findTooltip('下一页'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account-page-size')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5 条 / 页').last);
      await tester.pumpAndSettle();
      expect(find.text('账号 1'), findsOneWidget);
      expect(find.text('账号 6'), findsNothing);
      tester.view.physicalSize = const Size(400, 768);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final horizontal = find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      );
      await tester.drag(horizontal, const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(find.text('最近领取').hitTestable(), findsOneWidget);
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );

  testDesktopWidgets(
    'search sees off-page accounts and paging never activates them',
    (tester) async {
      var switches = 0;
      await mount(tester, activate: () => switches++);
      expect(find.text('账号 1'), findsOneWidget);
      expect(find.text('账号 11'), findsNothing);
      await tester.tap(findTooltip('下一页'));
      await tester.pumpAndSettle();
      expect(find.text('账号 11'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('account-search')),
        'user20@',
      );
      await tester.pumpAndSettle();
      expect(find.text('账号 20'), findsOneWidget);
      expect(find.text('账号 11'), findsNothing);
      expect(find.textContaining('120 积分'), findsOneWidget);
      await tester.tap(find.byKey(const Key('expiry-20')));
      await tester.pumpAndSettle();
      expect(find.textContaining('200 积分'), findsOneWidget);
      expect(find.textContaining('300 积分'), findsOneWidget);
      expect(find.textContaining('260 积分'), findsOneWidget);
      expect(switches, 0);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );

  testDesktopWidgets(
    'switch appears on hover, hides on leave, and uses its own row',
    (tester) async {
      var switches = 0;
      await mount(tester, activate: () => switches++);
      final target = find.byKey(const Key('activate-1'));
      expect(
        tester
            .widget<Opacity>(
              find.ancestor(of: target, matching: find.byType(Opacity)).first,
            )
            .opacity,
        0,
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byKey(const Key('account-1'))));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Opacity>(
              find.ancestor(of: target, matching: find.byType(Opacity)).first,
            )
            .opacity,
        1,
      );
      await tester.tap(target);
      expect(switches, 1);
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Opacity>(
              find.ancestor(of: target, matching: find.byType(Opacity)).first,
            )
            .opacity,
        0,
      );
      await mouse.removePointer();
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );
}
