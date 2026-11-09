import 'desktop_test_app.dart';

import 'package:material_ui/material_ui.dart';
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
  testDesktopWidgets(
    'secondary workspaces are reachable without example model credentials',
    (tester) async {
      await desktop(tester);
      for (final section in [
        'overview',
        'accounts',
        'models',
        'activity',
        'settings',
      ]) {
        await tester.tap(find.byKey(ValueKey('nav-$section')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('lp_demo'), findsNothing);
        expect(find.textContaining('127.0.0.1:5240'), findsNothing);
      }
    },
  );
  testDesktopWidgets('production navigation has regional account workspaces', (
    tester,
  ) async {
    await desktop(tester);
    for (final app in [
      'zcode',
      'qoderCn',
      'qoder',
      'minimaxCn',
      'minimax',
      'workbuddy',
      'traeCn',
      'codex',
    ]) {
      expect(find.byKey(ValueKey('app-$app')), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('app-$app')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('toggle-examples')), findsNothing);
      expect(find.byKey(const Key('backup-file')), findsNothing);
      expect(find.text('导入样例'), findsNothing);
      expect(find.text('ZCode 样例 A'), findsNothing);
      expect(find.byKey(const Key('switch-zcode-a')), findsNothing);
      expect(find.byKey(const Key('checkin-zcode-a')), findsNothing);
    }
  });

  for (final width in [480.0, 760.0, 1280.0]) {
    testDesktopWidgets(
      'app workspace has no layout exception at width $width',
      (tester) async {
        await desktop(tester, width: width);
        expect(tester.takeException(), isNull);
        if (width < 760) {
          expect(findTooltip('LoongPass'), findsOneWidget);
        } else {
          expect(find.text('LoongPass'), findsOneWidget);
        }
        expect(findTooltip('账号保存在本机；辅助任务仅在运行期间执行'), findsOneWidget);
        for (final app in [
          'zcode',
          'qoderCn',
          'qoder',
          'minimaxCn',
          'minimax',
          'workbuddy',
          'traeCn',
          'codex',
        ]) {
          await tester.tap(find.byKey(ValueKey('app-$app')));
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '$app at width $width',
          );
        }
      },
    );
  }
}
