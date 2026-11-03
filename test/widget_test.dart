import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/main.dart';

Future<void> desktop(WidgetTester tester, {double width = 1280}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(const AccountToolApp());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('desktop actions remain side by side within each account row', (
    tester,
  ) async {
    await desktop(tester);
    final switchRect = tester.getRect(find.byKey(const Key('switch-zcode-a')));
    final checkinRect = tester.getRect(
      find.byKey(const Key('checkin-zcode-a')),
    );
    final nextSwitch = tester.getRect(find.byKey(const Key('switch-zcode-b')));
    expect(switchRect.right, lessThanOrEqualTo(checkinRect.left));
    expect((switchRect.center.dy - checkinRect.center.dy).abs(), lessThan(1));
    expect(nextSwitch.top, greaterThanOrEqualTo(switchRect.bottom));
  });

  testWidgets('uses Material 3 and clearly labels synthetic-only operations', (
    tester,
  ) async {
    await desktop(tester);
    expect(find.text('LoongPass'), findsOneWidget);
    expect(find.text('开发预览'), findsOneWidget);
    expect(find.textContaining('不读取真实账号'), findsOneWidget);
    final context = tester.element(find.byType(Scaffold));
    expect(Theme.of(context).useMaterial3, isTrue);
    expect(find.text('WorkBuddy'), findsWidgets);
    expect(find.text('Qoder'), findsWidgets);
    expect(find.text('MiniMax Code'), findsWidgets);
    expect(find.text('ZCode'), findsWidgets);
  });

  testWidgets(
    'Mac backup cancellation restores button and never reports success',
    (tester) async {
      const channel = MethodChannel('com.sailingloong.loongpass/files');
      final pending = Completer<Object?>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) => pending.future,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await desktop(tester);
      await tester.tap(find.byKey(const Key('backup-file')));
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('backup-file')))
            .onPressed,
        isNull,
      );
      pending.complete(null);
      await tester.pumpAndSettle();
      expect(find.text('已取消，未备份任何文件。'), findsOneWidget);
      expect(find.text('备份已保存'), findsNothing);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('backup-file')))
            .onPressed,
        isNotNull,
      );
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );

  testWidgets('native backup failure is sanitized and can be retried', (
    tester,
  ) async {
    const channel = MethodChannel('com.sailingloong.loongpass/files');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async =>
          throw PlatformException(code: 'failed', message: 'DO_NOT_SHOW'),
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await desktop(tester);
    await tester.tap(find.byKey(const Key('backup-file')));
    await tester.pumpAndSettle();
    expect(find.text('无法打开本机备份入口。请检查 Mac 构建是否完整。'), findsOneWidget);
    expect(find.textContaining('DO_NOT_SHOW'), findsNothing);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('backup-file')))
          .onPressed,
      isNotNull,
    );
  }, variant: TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets('search filters account rows and clear restores them', (
    tester,
  ) async {
    await desktop(tester);
    await tester.enterText(find.byKey(const Key('account-search')), 'MiniMax');
    await tester.pumpAndSettle();
    expect(find.text('MiniMax 国内样例'), findsOneWidget);
    expect(find.text('MiniMax 国际样例'), findsOneWidget);
    expect(find.text('ZCode 样例 A'), findsNothing);
    await tester.enterText(find.byKey(const Key('account-search')), '');
    await tester.pumpAndSettle();
    expect(find.text('ZCode 样例 A'), findsOneWidget);
  });

  testWidgets('unmatched search shows useful empty state', (tester) async {
    await desktop(tester);
    await tester.enterText(
      find.byKey(const Key('account-search')),
      'no-such-account',
    );
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的账号'), findsOneWidget);
    expect(find.text('试试平台名称或账号备注。'), findsOneWidget);
  });

  testWidgets('import adds only an in-memory synthetic account', (
    tester,
  ) async {
    await desktop(tester);
    await tester.tap(find.text('导入样例'));
    await tester.pumpAndSettle();
    expect(find.textContaining('不会读取认证文件'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('import-label')), '新的合成账号');
    await tester.tap(find.byKey(const Key('confirm-import')));
    await tester.pumpAndSettle();
    expect(find.text('新的合成账号'), findsOneWidget);
    expect(find.text('9 个样例账号'), findsOneWidget);
    expect(find.text('已添加合成样例，未读取任何认证文件。'), findsOneWidget);
  });

  testWidgets('cancel import does not add an account', (tester) async {
    await desktop(tester);
    await tester.tap(find.text('导入样例'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('8 个样例账号'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('empty import label is rejected without closing the dialog', (
    tester,
  ) async {
    await desktop(tester);
    await tester.tap(find.text('导入样例'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('import-label')), '   ');
    await tester.tap(find.byKey(const Key('confirm-import')));
    await tester.pumpAndSettle();
    expect(find.text('请输入账号备注'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('8 个样例账号'), findsOneWidget);
  });

  testWidgets(
    'switching a ZCode sample updates selected row through pure core',
    (tester) async {
      await desktop(tester);
      expect(find.byKey(const Key('current-zcode-a')), findsOneWidget);
      await tester.tap(find.byKey(const Key('switch-zcode-b')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('current-zcode-b')), findsOneWidget);
      expect(find.byKey(const Key('current-zcode-a')), findsNothing);
      expect(find.text('仅切换了合成样例，原生客户端未改变。'), findsOneWidget);
      await tester.tap(find.byKey(const Key('switch-zcode-a')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('current-zcode-a')), findsOneWidget);
    },
  );

  testWidgets('unsupported native switches and check-in are disabled', (
    tester,
  ) async {
    await desktop(tester);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('backup-file')))
          .onPressed,
      isNull,
    );
    final unsupported = tester.widget<OutlinedButton>(
      find.byKey(const Key('switch-qoder-cn')),
    );
    expect(unsupported.onPressed, isNull);
    final checkin = tester.widget<OutlinedButton>(
      find.byKey(const Key('checkin-zcode-a')),
    );
    expect(checkin.onPressed, isNull);
    expect(find.text('未接入'), findsWidgets);
    expect(find.text('签到成功'), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const Key('auto-checkin')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final auto = tester.widget<Switch>(find.byKey(const Key('auto-checkin')));
    expect(auto.value, isFalse);
    expect(auto.onChanged, isNull);
  });

  for (final width in [480.0, 760.0, 1280.0]) {
    testWidgets('account page has no layout exceptions at width $width', (
      tester,
    ) async {
      await desktop(tester, width: width);
      expect(tester.takeException(), isNull);
      expect(find.text('LoongPass'), findsOneWidget);
      expect(find.byKey(const Key('account-search')), findsOneWidget);
    });
  }
}
