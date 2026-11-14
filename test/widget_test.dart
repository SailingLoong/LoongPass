import 'desktop_test_app.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/main.dart';
import '../lib/app_sidebar.dart';

Future<void> desktop(WidgetTester tester, {double width = 1280}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(const AccountToolApp());
  await tester.pumpAndSettle();
}

Future<void> openInvitation(WidgetTester tester, String platform) async {
  await tester.tap(find.byKey(const Key('nav-settings')));
  await tester.pumpAndSettle();
  final section = find.byKey(Key('invitation-$platform'));
  await tester.ensureVisible(section);
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(of: section, matching: find.textContaining('邀请设置')).first,
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(Key('$platform-invitation-code')));
  await tester.pumpAndSettle();
}

void main() {
  testDesktopWidgets(
    'invitation settings remain isolated and survive navigation',
    (tester) async {
      await desktop(tester);
      await openInvitation(tester, 'qoderCn');
      expect(find.text('n1SqSmAhYt8nJKTkFM2QyB5IJ0DWROl3'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('qoderCn-invitation-code')),
        'custom-qoder-code',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('qoderCn-invitation-save')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('qoderCn-invitation-save')));
      await tester.pumpAndSettle();
      expect(find.text('邀请码已保存'), findsOneWidget);
      await openInvitation(tester, 'workbuddy');
      expect(find.text('3wu5mr8ye2b0'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('workbuddy-invitation-code')),
        'unsaved-workbuddy',
      );
      await tester.tap(find.byKey(const Key('nav-accounts')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workbuddy-invitation-code')), findsNothing);
      await tester.tap(find.byKey(const Key('nav-settings')));
      await tester.pumpAndSettle();
      expect(find.text('unsaved-workbuddy'), findsOneWidget);
      expect(find.text('custom-qoder-code'), findsOneWidget);
    },
  );

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
  for (final width in [480.0, 760.0, 1280.0]) {
    testDesktopWidgets(
      'all regional workspaces remain available at width $width',
      (tester) async {
        await desktop(tester, width: width);
        final workspace = tester.state<AppWorkspaceState>(
          find.byType(AppWorkspace),
        );
        for (final app in ManagedApp.values) {
          workspace.selectApp(app);
          await tester.pumpAndSettle();
          expect(find.byKey(ValueKey('page-${app.name}')), findsOneWidget);
          expect(find.byKey(const Key('account-apps')), findsOneWidget);
          expect(find.byKey(const Key('platform-filter')), findsNothing);
          expect(
            tester.takeException(),
            isNull,
            reason: '${app.name} at $width',
          );
          expect(find.text('导入样例'), findsNothing);
        }
      },
    );
  }
}
