import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import '../lib/app_update_view.dart';
import '../lib/credit_summary_view.dart';
import '../lib/update_contract.dart';
import '../lib/workspace_tools.dart';

Future<void> tapWorkspaceDestination(
  WidgetTester tester,
  String section,
  Future<void> Function() frame,
) async {
  final destination = find.byKey(ValueKey('nav-$section'));
  if (destination.hitTestable().evaluate().isEmpty) {
    await tester.tap(find.byKey(const Key('toggle-sidebar')));
    await frame();
  }
  await tester.tap(destination.hitTestable());
  await frame();
}

Future<void> inspectCalendarReturn(
  WidgetTester tester,
  String account,
  DateTime laterBatch,
  Future<void> Function() frame,
  Future<void> Function(String) capture,
) async {
  final day = find.byKey(const Key('expiry-day-4'));
  await tester.ensureVisible(day);
  await tester.tap(day);
  await frame();
  final entry = find.widgetWithText(FItem, account);
  await tester.ensureVisible(entry);
  expect(
    find.descendant(of: entry, matching: find.text('100 credits')),
    findsOneWidget,
  );
  await tester.tap(entry);
  await frame();
  final detail = find.byKey(const Key('account-detail-page'));
  final selected = find.descendant(
    of: detail,
    matching: find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.selected == true,
    ),
  );
  expect(
    find.descendant(of: selected, matching: find.text(creditTime(laterBatch))),
    findsOneWidget,
  );
  expect(
    find.descendant(of: selected, matching: find.text('100 credits')),
    findsOneWidget,
  );
  expect(
    find.descendant(of: detail, matching: find.text('到期明细')),
    findsOneWidget,
  );
  await capture('calendar-batch');
  await tester.tap(find.byKey(const Key('account-back')));
  await frame();
  expect(tester.widget<FTappable>(day).selected, isTrue);
  expect(
    find.descendant(of: entry, matching: find.text('100 credits')),
    findsOneWidget,
  );
  await capture('calendar-return');
}

Future<void> inspectAccountReturn(
  WidgetTester tester,
  String account,
  DateTime nextExpiry,
  DateTime observedAt,
  Future<void> Function() frame,
  Future<void> Function(String) capture,
) async {
  final search = find.byKey(const Key('account-search'));
  await tester.ensureVisible(search);
  await tester.enterText(search, account);
  await frame();
  final entry = find.byKey(const Key('account-minimaxCn/studio'));
  await tester.ensureVisible(entry);
  final position = Scrollable.of(tester.element(entry)).position.pixels;
  await tester.tap(entry);
  await frame();
  final detail = find.byKey(const Key('account-detail-page'));
  final body = tester.getRect(find.byKey(const ValueKey('workspace-body')));
  final page = tester.getRect(detail);
  expect(page.left, closeTo(body.left, 1));
  expect(page.right, closeTo(body.right, 1));
  if (tester.view.physicalSize.width >= 620) {
    final sidebar = find.byKey(const Key('app-sidebar'));
    expect(
      find.descendant(of: sidebar, matching: find.text('模型连接')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.getRect(sidebar).right, closeTo(page.left, 1));
  }
  expect(entry.hitTestable(), findsNothing);
  for (final text in ['13,224 credits', '1,424 credits', '+400 credits']) {
    expect(
      find.descendant(of: detail, matching: find.text(text)),
      findsOneWidget,
    );
  }
  await capture('detail');
  final observedDay = '${observedAt.month}月${observedAt.day}日';
  for (final value in [
    find.textContaining('${nextExpiry.month}月${nextExpiry.day}日 00:00'),
    find.text('核验于 $observedDay 11:26'),
    find.textContaining('$observedDay 16:48 查询'),
  ]) {
    final text = find.descendant(of: detail, matching: value);
    expect(text, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: text, matching: find.byType(RichText)),
    );
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: paragraph.text.toPlainText(),
    );
  }
  final back = find.byKey(const Key('account-back'));
  for (final section in ['expiry', 'receipt', 'quota']) {
    final link = find.byKey(ValueKey('detail-$section'));
    await tester.ensureVisible(link);
    await tester.tap(link);
    await frame();
    if (section == 'expiry') {
      expect(
        find.descendant(
          of: detail,
          matching: find.text(creditTime(nextExpiry)),
        ),
        findsOneWidget,
      );
      expect(find.textContaining(RegExp(r'^1,?424 credits$')), findsOneWidget);
    } else if (section == 'receipt') {
      final date = observedAt.toLocal().toString().substring(0, 16);
      expect(
        find.descendant(
          of: detail,
          matching: find.text('+400 credits · 核验于 $date'),
        ),
        findsOneWidget,
      );
    } else {
      expect(
        find.descendant(of: detail, matching: find.text('套餐与额度')),
        findsOneWidget,
      );
    }
    await capture(section);
    await tester.tap(back);
    await frame();
  }
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await frame();
  expect(detail, findsNothing);
  final input = find.descendant(
    of: search,
    matching: find.byType(EditableText),
  );
  expect(tester.widget<EditableText>(input).controller.text, account);
  expect(entry.hitTestable(), findsOneWidget);
  expect(tester.widget<FButton>(entry).selected, isTrue);
  expect(
    Scrollable.of(tester.element(entry)).position.pixels,
    closeTo(position, 1),
  );
  await capture('account-return');
}

Future<void> inspectModelReturn(
  WidgetTester tester,
  Future<void> Function() frame,
  Future<void> Function(String) capture,
) async {
  Finder key(String value) => find.byKey(ValueKey(value));
  Future<void> tapInPage(Finder control, {bool towardsTop = false}) async {
    if (control.evaluate().isEmpty) {
      final page = find
          .descendant(
            of: find.byType(WorkspacePage),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        control,
        towardsTop ? -180 : 180,
        scrollable: page,
      );
    }
    await tester.ensureVisible(control);
    await frame();
    await tester.tap(control.hitTestable());
    await frame();
  }

  final back = find.widgetWithText(FButton, '全部模型');
  final search = key('model-search');
  final hint = find.descendant(of: search, matching: find.text('搜索模型、别名或套餐'));
  expect(hint, findsOneWidget);
  final hintText = tester.renderObject<RenderParagraph>(
    find.descendant(of: hint, matching: find.byType(RichText)),
  );
  expect(hintText.didExceedMaxLines, isFalse);
  await tapInPage(key('open-auto-routing'));
  await capture('auto');
  await tapInPage(back, towardsTop: true);
  await tester.ensureVisible(search);
  await tester.enterText(search, '1017');
  await frame();
  expect(key('model-MiniMax-M3'), findsNothing);
  await capture('filtered');
  await tapInPage(key('open-model-deepseek-flash'));
  await capture('detail');
  final sourceName = find.text('日常账号 14');
  expect(sourceName, findsNothing);
  await tapInPage(find.text('Qoder CN · 套餐待核实'));
  await tapInPage(sourceName);
  final account = key('account-detail-page');
  expect(find.descendant(of: account, matching: sourceName), findsOneWidget);
  final workArea = tester.getRect(key('workspace-body'));
  expect(tester.getRect(account).left, closeTo(workArea.left, 1));
  expect(tester.getRect(account).right, closeTo(workArea.right, 1));
  await capture('source-account');
  await tester.tap(key('account-back'));
  await frame();
  expect(key('model-account-saved-13'), findsOneWidget);
  expect(sourceName.hitTestable(), findsOneWidget);
  await tapInPage(find.text('返回模型'), towardsTop: true);
  await capture('returned-model');
  await tapInPage(back, towardsTop: true);
  final input = find.descendant(
    of: search,
    matching: find.byType(EditableText),
  );
  expect(tester.widget<EditableText>(input).controller.text, '1017');
  expect(key('open-model-deepseek-flash'), findsOneWidget);
  expect(key('model-MiniMax-M3'), findsNothing);
  await capture('returned-search');
}

Future<void> inspectSettings(
  WidgetTester tester,
  Future<void> Function() frame,
  Future<void> Function(String) capture,
) async {
  final content = {
    SettingsSection.appearance: find.byKey(const Key('appearance-theme')),
    SettingsSection.platforms: find.byKey(const Key('platform-order-settings')),
    SettingsSection.updates: find.byType(AppUpdateCard),
    SettingsSection.data: find.textContaining('明文'),
  };
  for (final entry in content.entries) {
    final tab = find.byKey(ValueKey(entry.key));
    await tester.ensureVisible(tab);
    await frame();
    await tester.tap(tab.hitTestable());
    await frame();
    expect(entry.value, findsOneWidget);
    await capture('settings-${entry.key.name}');
  }
}

Future<void> inspectUpdateRail(
  WidgetTester tester,
  Map<String, Object?> snapshot,
  bool narrow,
  Future<void> Function() frame,
  Future<void> Function(String) capture,
) async {
  if (narrow) {
    await tester.tap(find.byKey(const Key('toggle-sidebar')));
    await frame();
  }
  final rail = find.descendant(
    of: find.byKey(const Key('app-sidebar')),
    matching: find.byType(AppUpdateBadge),
  );
  var revision = 2;
  for (final (scene, phase, progress) in [
    ('known', 'downloading', .25),
    ('unknown', 'downloading', null),
    ('failure', 'error', null),
    ('ready', 'ready', null),
  ]) {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      UpdateContract.channel,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(UpdateContract.stateChanged, {
          ...snapshot,
          'revision': ++revision,
          'phase': phase,
          'progress': progress,
          'canInstall': phase == 'ready',
          'canCheck': phase == 'error',
          'error': phase == 'error' ? '下载中断，请重试。' : null,
        }),
      ),
      (_) {},
    );
    await frame();
    if (scene == 'known') {
      // Forui animates a newly mounted determinate bar from zero.
      await tester.pump(const Duration(seconds: 2));
    }
    await capture('rail-$scene');
    final ready = find.descendant(of: rail, matching: find.text('重启并更新'));
    expect(ready, scene == 'ready' ? findsOneWidget : findsNothing);
    final percent = find.descendant(of: rail, matching: find.text('25%'));
    expect(percent, scene == 'known' ? findsOneWidget : findsNothing);
    if (scene == 'unknown') {
      expect(
        find.descendant(of: rail, matching: find.text('进度未知')),
        findsOneWidget,
      );
    }
    if (scene == 'failure') {
      final failure = find.descendant(
        of: rail,
        matching: find.textContaining('未完成'),
      );
      expect(failure, findsWidgets);
      await tester.tap(failure.hitTestable().first);
      await frame();
      expect(find.text('下载中断，请重试。'), findsOneWidget);
      await capture('failure-settings');
      if (narrow) {
        expect(find.text('更新失败').hitTestable(), findsOneWidget);
        await tester.tap(find.byKey(const Key('toggle-sidebar')));
        await frame();
      }
    }
  }
}
