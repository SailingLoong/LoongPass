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
  testWidgets('production navigation has only four app workspaces', (tester) async {
    await desktop(tester);
    for (final app in ['zcode', 'qoder', 'minimax', 'workbuddy']) {
      expect(find.byKey(ValueKey('app-$app')), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('app-$app')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('toggle-examples')), findsNothing);
      expect(find.byKey(const Key('backup-file')), findsNothing);
      expect(find.byKey(const Key('account-search')), findsNothing);
      expect(find.text('导入样例'), findsNothing);
      expect(find.text('ZCode 样例 A'), findsNothing);
      expect(find.byKey(const Key('switch-zcode-a')), findsNothing);
      expect(find.byKey(const Key('checkin-zcode-a')), findsNothing);
    }
  });

  testWidgets('Qoder entry requires app navigation and remains unverified', (tester) async {
    await desktop(tester);
    expect(find.byKey(const Key('qoder-import-file')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('app-qoder')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('qoder-import-file')), findsOneWidget);
    expect(find.text('尚未导入账号'), findsOneWidget);
    expect(find.text('签到成功'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('app-zcode')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('qoder-import-file')), findsNothing);
  });

  for (final width in [480.0, 760.0, 1280.0]) {
    testWidgets('app workspace has no layout exception at width $width', (tester) async {
      await desktop(tester, width: width);
      expect(tester.takeException(), isNull);
      if (width < 760) {
        expect(find.byTooltip('LoongPass'), findsOneWidget);
      } else {
        expect(find.text('LoongPass'), findsOneWidget);
      }
      expect(find.text('开发预览'), findsOneWidget);
      for (final app in ['zcode', 'qoder', 'minimax', 'workbuddy']) {
        await tester.tap(find.byKey(ValueKey('app-$app')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$app at width $width');
      }
    });
  }
}
