import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/app_updates.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.sailingloong.loongpass/updates');
  late Map<String, Object?> native;
  late List<MethodCall> calls;
  var failSave = false;
  setUp(() {
    native = {
      'version': '1.0.0 (30)',
      'canCheck': true,
      'canChangeChannel': true,
      'automaticUpdates': false,
      'receiveBetaUpdates': false,
    };
    calls = [];
    failSave = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'setAutomaticUpdates' ||
              call.method == 'setReceiveBetaUpdates') {
            if (failSave) throw PlatformException(code: 'unavailable');
            native[call.method == 'setAutomaticUpdates'
                    ? 'automaticUpdates'
                    : 'receiveBetaUpdates'] =
                call.arguments;
          }
          return native;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  Future<AppUpdates> render(WidgetTester tester) async {
    final updates = AppUpdates();
    await updates.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AppUpdateCard(updates: updates)),
      ),
    );
    return updates;
  }

  bool enabled(WidgetTester tester, String label) => tester
      .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, label))
      .value;

  testWidgets(
    'opening settings only reads state; manual checks remain explicit',
    (tester) async {
      final updates = await render(tester);
      addTearDown(updates.dispose);
      expect(find.text('当前版本 1.0.0 (30)'), findsOneWidget);
      expect(calls.map((c) => c.method), ['state']);
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      expect(calls.map((c) => c.method), ['state', 'check']);
    },
  );

  testWidgets(
    'automatic updates and beta are two independent native preferences',
    (tester) async {
      final updates = await render(tester);
      addTearDown(updates.dispose);
      expect(find.byType(SwitchListTile), findsNWidgets(2));
      expect(find.text('自动检查并下载更新'), findsOneWidget);
      expect(find.text('接收 Beta 版更新'), findsOneWidget);
      await tester.tap(find.text('自动检查并下载更新'));
      await tester.pumpAndSettle();
      expect(enabled(tester, '自动检查并下载更新'), isTrue);
      expect(enabled(tester, '接收 Beta 版更新'), isFalse);
      expect(calls.last.method, 'setAutomaticUpdates');
      expect(calls.last.arguments, true);
      await tester.tap(find.text('自动检查并下载更新'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('接收 Beta 版更新'));
      await tester.pumpAndSettle();
      expect(enabled(tester, '自动检查并下载更新'), isFalse);
      expect(enabled(tester, '接收 Beta 版更新'), isTrue);
      expect(calls.last.method, 'setReceiveBetaUpdates');
      expect(calls.last.arguments, true);
    },
  );

  testWidgets(
    'save failure keeps native preferences and reload restores them',
    (tester) async {
      final updates = await render(tester);
      await tester.tap(find.text('自动检查并下载更新'));
      await tester.pumpAndSettle();
      failSave = true;
      await tester.tap(find.text('接收 Beta 版更新'));
      await tester.pumpAndSettle();
      expect(enabled(tester, '接收 Beta 版更新'), isFalse);
      expect(find.text('更新操作未完成，请稍后重试。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      updates.dispose();
      final restored = await render(tester);
      addTearDown(restored.dispose);
      expect(enabled(tester, '自动检查并下载更新'), isTrue);
      expect(enabled(tester, '接收 Beta 版更新'), isFalse);
    },
  );

  testWidgets(
    'active native update prevents another check and channel switch',
    (tester) async {
      native['canCheck'] = false;
      native['canChangeChannel'] = false;
      final updates = await render(tester);
      addTearDown(updates.dispose);
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, '接收 Beta 版更新'),
            )
            .onChanged,
        isNull,
      );
      expect(calls.map((c) => c.method), ['state']);
    },
  );
}
