import 'dart:async';

import 'desktop_test_app.dart';

import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/app_updates.dart';
import '../lib/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.sailingloong.loongpass/updates');
  late Map<String, Object?> native;
  late List<MethodCall> calls;
  var failSave = false;
  Completer<Object?>? pending;
  setUp(() {
    native = {
      'revision': 0,
      'phase': 'idle',
      'version': '1.0.0 (30)',
      'canCheck': true,
      'canChangeChannel': true,
      'automaticUpdates': false,
      'receiveBetaUpdates': false,
    };
    calls = [];
    failSave = false;
    pending = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (pending != null && call.method != 'state') return pending!.future;
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
      DesktopTestApp(
        home: Scaffold(body: AppUpdateCard(updates: updates)),
      ),
    );
    return updates;
  }

  bool enabled(WidgetTester tester, String label) =>
      tester.widget<FSwitch>(find.widgetWithText(FSwitch, label)).value;

  testDesktopWidgets(
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

  testDesktopWidgets(
    'automatic updates and beta are two independent native preferences',
    (tester) async {
      final updates = await render(tester);
      addTearDown(updates.dispose);
      expect(find.byType(FSwitch), findsNWidgets(2));
      expect(find.text('自动检查并预下载更新'), findsOneWidget);
      expect(find.text('接收 Beta 版更新'), findsOneWidget);
      await tester.tap(find.text('自动检查并预下载更新'));
      await tester.pumpAndSettle();
      expect(enabled(tester, '自动检查并预下载更新'), isTrue);
      expect(enabled(tester, '接收 Beta 版更新'), isFalse);
      expect(calls.last.method, 'setAutomaticUpdates');
      expect(calls.last.arguments, true);
      await tester.tap(find.text('自动检查并预下载更新'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('接收 Beta 版更新'));
      await tester.pumpAndSettle();
      expect(enabled(tester, '自动检查并预下载更新'), isFalse);
      expect(enabled(tester, '接收 Beta 版更新'), isTrue);
      expect(calls.last.method, 'setReceiveBetaUpdates');
      expect(calls.last.arguments, true);
    },
  );

  testDesktopWidgets(
    'save failure keeps native preferences and reload restores them',
    (tester) async {
      final updates = await render(tester);
      await tester.tap(find.text('自动检查并预下载更新'));
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
      expect(enabled(tester, '自动检查并预下载更新'), isTrue);
      expect(enabled(tester, '接收 Beta 版更新'), isFalse);
    },
  );

  testDesktopWidgets(
    'active native update prevents another check and channel switch',
    (tester) async {
      native['canCheck'] = false;
      native['canChangeChannel'] = false;
      final updates = await render(tester);
      addTearDown(updates.dispose);
      expect(tester.widget<FButton>(find.byType(FButton)).onPress, isNull);
      expect(
        tester
            .widget<FSwitch>(find.widgetWithText(FSwitch, '接收 Beta 版更新'))
            .enabled,
        isFalse,
      );
      expect(calls.map((c) => c.method), ['state']);
    },
  );

  Future<void> event(WidgetTester tester, Map<String, Object?> value) async {
    final completed = Completer<void>();
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('stateChanged', value),
      ),
      (_) => completed.complete(),
    );
    await completed.future;
    await tester.pump();
  }

  testDesktopWidgets(
    'a prepared update installs once without checking or downloading again',
    (tester) async {
      native.addAll({
        'phase': 'ready',
        'offeredVersion': '1.0.1',
        'canInstall': true,
        'canCheck': false,
        'canSkip': true,
      });
      final updates = await render(tester);
      addTearDown(updates.dispose);
      expect(find.text('更新已准备好，可重启并更新'), findsOneWidget);
      pending = Completer<Object?>();
      await tester.tap(find.text('重启并更新'));
      await tester.pump();
      await tester.tap(find.text('重启并更新'));
      await tester.pump();
      expect(calls.map((c) => c.method), ['state', 'install']);
      pending!.complete({
        ...native,
        'revision': 1,
        'phase': 'installing',
        'canInstall': false,
        'canSkip': false,
      });
      await tester.pumpAndSettle();
      expect(find.text('正在安装更新'), findsOneWidget);
    },
  );

  testDesktopWidgets(
    'download progress is inline and unknown totals stay indeterminate',
    (tester) async {
      native.addAll({
        'phase': 'downloading',
        'offeredVersion': '1.0.1',
        'canCheck': false,
      });
      final updates = await render(tester);
      addTearDown(updates.dispose);
      expect(find.byType(FProgress), findsOneWidget);
      expect(find.text('重启并更新'), findsNothing);
      expect(calls.map((c) => c.method), ['state']);
      await event(tester, {...native, 'revision': 1, 'progress': 0.25});
      expect(
        tester
            .widget<FDeterminateProgress>(find.byType(FDeterminateProgress))
            .value,
        0.25,
      );
    },
  );

  testDesktopWidgets(
    'a late check reply cannot overwrite a newer ready event',
    (tester) async {
      final updates = await render(tester);
      addTearDown(updates.dispose);
      pending = Completer<Object?>();
      await tester.tap(find.text('检查更新'));
      await tester.pump();
      await event(tester, {
        ...native,
        'revision': 2,
        'phase': 'ready',
        'offeredVersion': '1.0.1',
        'canInstall': true,
        'canCheck': false,
      });
      pending!.complete({...native, 'revision': 1, 'phase': 'checking'});
      await tester.pumpAndSettle();
      expect(find.text('更新已准备好，可重启并更新'), findsOneWidget);
      expect(find.text('正在检查更新'), findsNothing);
    },
  );

  testDesktopWidgets('update badge fits expanded and collapsed navigation in both themes', (tester) async {
    native.addAll({'phase': 'preparing', 'canCheck': false});
    final updates = AppUpdates();
    await updates.load();
    addTearDown(updates.dispose);
    for (final brightness in Brightness.values) {
      for (final width in [64.0, 196.0]) {
        await tester.pumpWidget(DesktopTestApp(
          theme: loongPassTheme(brightness),
          home: Center(child: SizedBox(width: width, child: AppUpdateBadge(
            updates: updates, compact: width == 64, onOpen: () {},
          ))),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    }
    expect(calls.map((call) => call.method), ['state']);
  });
}
