import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/app_update_view.dart';
import '../lib/update_contract.dart';
import '../lib/workspace_tools.dart';

Future<void> inspectSettings(
  WidgetTester tester,
  Future<void> Function() frame,
  Future<void> Function(String) capture,
) async {
  const titles = {
    SettingsSection.appearance: '界面偏好',
    SettingsSection.platforms: '平台顺序',
    SettingsSection.updates: '版本与更新',
    SettingsSection.data: '本机数据',
  };
  if (tester.view.physicalSize.width / tester.view.devicePixelRatio == 480) {
    for (final topic in titles.keys) {
      expect(find.byKey(ValueKey(topic)).hitTestable(), findsOneWidget);
    }
  }
  for (final entry in titles.entries) {
    final tab = find.byKey(ValueKey(entry.key));
    await tester.tap(tab.hitTestable());
    await frame();
    expect(find.text(entry.value).hitTestable(), findsOneWidget);
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
