import 'dart:async';
import 'dart:ui' show PointerDeviceKind, SemanticsAction;

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
      expect(find.text('版本与更新'), findsOneWidget);
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
    'locked channel guidance follows native update permissions',
    (tester) async {
      final updates = await render(tester);
      addTearDown(updates.dispose);
      final channelSwitch = find.widgetWithText(FSwitch, '接收 Beta 版更新');
      var revision = 0;
      for (final (phase, install, skip, description) in [
        ('downloading', false, false, '正在下载更新，暂时无法切换渠道。'),
        ('ready', true, false, '安装本次更新后可切换渠道。'),
        ('ready', true, true, '安装或放弃本次更新后可切换渠道。'),
        ('installing', false, false, '暂时无法切换更新渠道。'),
      ]) {
        await event(tester, {
          ...native,
          'revision': ++revision,
          'phase': phase,
          'canChangeChannel': false,
          'canInstall': install,
          'canSkip': skip,
          'canCheck': false,
        });
        expect(tester.widget<FSwitch>(channelSwitch).enabled, isFalse);
        expect(
          find.descendant(of: channelSwitch, matching: find.text(description)),
          findsOneWidget,
        );
        expect(find.text('放弃本次更新'), skip ? findsOneWidget : findsNothing);
        expect(find.text('重启并更新'), install ? findsOneWidget : findsNothing);
      }
      await event(tester, {
        ...native,
        'revision': ++revision,
        'phase': 'upToDate',
      });
      expect(tester.widget<FSwitch>(channelSwitch).enabled, isTrue);
      expect(calls.map((call) => call.method), ['state']);
    },
  );

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
      await tester.pumpAndSettle();
      expect(calls.map((c) => c.method), ['state']);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(calls.map((c) => c.method), ['state']);
      await tester.tap(find.text('重启并更新'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认重启'));
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
    'download bytes show live speed, percentage and stalls without another check',
    (tester) async {
      native.addAll({
        'phase': 'downloading',
        'canCheck': false,
        'progress': 0.0,
        'downloadedBytes': 0,
      });
      final updates = await render(tester);
      addTearDown(updates.dispose);
      expect(find.text('0%'), findsOneWidget);
      await event(tester, {
        ...native,
        'revision': 1,
        'progress': 0.25,
        'downloadedBytes': 1048576,
      });
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('25%'), findsOneWidget);
      expect(find.text('1.0 MiB/s'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('0 B/s'), findsOneWidget);
      await event(tester, {
        ...native,
        'revision': 2,
        'phase': 'preparing',
        'progress': null,
      });
      expect(find.text('1.0 MiB/s'), findsNothing);
      expect(find.text('0 B/s'), findsNothing);
      expect(calls.map((c) => c.method), ['state']);
    },
  );

  testDesktopWidgets(
    'unknown totals and replacement downloads do not inherit telemetry',
    (tester) async {
      native.addAll({
        'phase': 'downloading',
        'canCheck': false,
        'downloadedBytes': 0,
      });
      final updates = await render(tester);
      addTearDown(updates.dispose);
      expect(find.text('进度未知'), findsOneWidget);
      await event(tester, {...native, 'revision': 1, 'downloadedBytes': 2048});
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('2.0 KiB/s'), findsOneWidget);
      expect(find.byType(FProgress), findsOneWidget);
      await event(tester, {...native, 'revision': 2, 'downloadedBytes': 0});
      expect(find.text('计算速度…'), findsOneWidget);
      await event(tester, {...native, 'revision': 1, 'downloadedBytes': 2048});
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('0 B/s'), findsOneWidget);
      expect(updates.downloadedBytes, 0);
    },
  );

  testDesktopWidgets(
    'check dates come from the native schedule and disappear on opt-out',
    (tester) async {
      native.addAll({
        'automaticUpdates': true,
        'lastCheckAt': DateTime(2026, 11, 15, 12).millisecondsSinceEpoch,
        'nextCheckAt': DateTime(2026, 11, 15, 13).millisecondsSinceEpoch,
      });
      final updates = await render(tester);
      addTearDown(updates.dispose);
      expect(find.text('11-15 12:00'), findsOneWidget);
      expect(find.text('约 11-15 13:00'), findsOneWidget);
      await tester.tap(find.text('自动检查并预下载更新'));
      await tester.pumpAndSettle();
      expect(find.text('约 11-15 13:00'), findsNothing);
      expect(find.text('11-15 12:00'), findsOneWidget);
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

  testDesktopWidgets(
    'download rail uses the reference colors with readable fill contrast',
    (tester) async {
      native.addAll({'phase': 'downloading', 'progress': .25});
      final updates = AppUpdates();
      await updates.load();
      addTearDown(updates.dispose);
      for (final (mode, trackColor, fillColor) in const [
        (Brightness.light, Color(0xffe5e5e5), Color(0xff2658d9)),
        (Brightness.dark, Color(0xff35373b), Color(0xff86a9ff)),
      ]) {
        await tester.pumpWidget(
          DesktopTestApp(
            key: ValueKey(mode),
            theme: loongPassTheme(mode),
            home: Center(
              child: SizedBox(
                width: 196,
                child: AppUpdateBadge(
                  updates: updates,
                  compact: false,
                  onOpen: () {},
                ),
              ),
            ),
          ),
        );
        final progress = find.byType(FDeterminateProgress);
        final decorations = tester.widgetList<DecoratedBox>(
          find.descendant(of: progress, matching: find.byType(DecoratedBox)),
        );
        final track = decorations.first.decoration;
        final color = switch (track) {
          BoxDecoration(:final color) ||
          ShapeDecoration(:final color) => color!,
          _ => throw StateError('Unknown track decoration'),
        };
        final fill = (decorations.last.decoration as BoxDecoration).color!;
        expect(color, trackColor);
        expect(fill, fillColor);
        final luminances = [fill.computeLuminance(), color.computeLuminance()]
          ..sort();
        expect(
          (luminances.last + .05) / (luminances.first + .05),
          greaterThan(4.5),
        );
        expect(tester.widget<FDeterminateProgress>(progress).value, .25);
      }
    },
  );

  testDesktopWidgets(
    'update badge fits each state and preserves labels and actions',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        for (final (phase, label) in [
          (UpdatePhase.error, '更新未完成，可稍后重试'),
          (UpdatePhase.ready, '重启并更新'),
          (UpdatePhase.downloading, '正在后台下载更新 · 进度未知 · 计算速度…'),
          (UpdatePhase.preparing, '正在校验并准备更新'),
        ]) {
          native.addAll({
            'phase': phase.name,
            'canCheck': phase == UpdatePhase.error,
            'canInstall': phase == UpdatePhase.ready,
          });
          final updates = AppUpdates();
          await updates.load();
          addTearDown(updates.dispose);
          var opens = 0;
          for (final brightness in Brightness.values) {
            for (final width in [56.0, 64.0, 176.0, 208.0]) {
              for (final scale in [1.0, 2.0]) {
                await tester.pumpWidget(
                  DesktopTestApp(
                    theme: loongPassTheme(brightness),
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(textScaler: TextScaler.linear(scale)),
                      child: child!,
                    ),
                    home: Center(
                      child: SizedBox(
                        width: width,
                        child: AppUpdateBadge(
                          updates: updates,
                          compact: width <= 64,
                          onOpen: () => opens++,
                        ),
                      ),
                    ),
                  ),
                );
                await tester.pump();
                expect(tester.takeException(), isNull);
                final labeledButton = find.descendant(
                  of: find.byType(FButton),
                  matching: find.byWidgetPredicate(
                    (widget) =>
                        widget is Semantics && widget.properties.label == label,
                  ),
                );
                expect(labeledButton, findsOneWidget);
                final data = tester
                    .getSemantics(labeledButton)
                    .getSemanticsData();
                expect(data.label, label);
                expect(data.flagsCollection.isButton, isTrue);
                expect(data.hasAction(SemanticsAction.tap), isTrue);
                expect(find.byType(FTooltip), findsOneWidget);
              }
            }
          }
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(tester.getCenter(find.byType(FButton)));
          await tester.pump(const Duration(seconds: 1));
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            find.text(label),
            (phase == UpdatePhase.downloading || phase == UpdatePhase.error)
                ? findsOneWidget
                : findsNWidgets(2),
          );
          await mouse.removePointer();
          await tester.pump(const Duration(milliseconds: 300));
          final callsBeforePress = calls.length;
          expect(find.byType(FButton), findsOneWidget);
          final target = phase == UpdatePhase.error
              ? find.text('查看原因')
              : find.byType(FButton);
          await tester.tap(target);
          await tester.pump(const Duration(milliseconds: 300));
          expect(opens, phase == UpdatePhase.ready ? 0 : 1);
          expect(calls.skip(callsBeforePress), isEmpty);
          if (phase == UpdatePhase.ready) {
            await tester.pumpAndSettle();
            await tester.tap(find.text('取消'));
            await tester.pumpAndSettle();
            expect(calls.skip(callsBeforePress), isEmpty);
          }
        }
      } finally {
        semantics.dispose();
      }
    },
  );
}
