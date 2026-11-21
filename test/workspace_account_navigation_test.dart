import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

import '../lib/main.dart';
import 'desktop_test_app.dart';
import 'model_workspace_fixture.dart';

void main() {
  testDesktopWidgets(
    'workspace destinations browse without authorization; the selected add-account target starts once',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1080, 748);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      const channel = MethodChannel('com.sailingloong.loongpass/files');
      final messenger = tester.binding.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return {
          'available': true,
          'accounts': [],
          'loginPending': false,
          'busy': false,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final app = ModelWorkspaceFixture();
      addTearDown(app.dispose);
      await tester.pumpWidget(AccountToolApp(application: app));
      await tester.pumpAndSettle();
      Future<void> click(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      final overview = find.byKey(const Key('nav-overview'));
      await click(overview);
      await click(find.byKey(const Key('nav-activity')));
      await click(find.text('最近领取 0'));
      expect(find.text('暂无已确认的领取记录。'), findsOneWidget);
      await click(find.byKey(const Key('nav-accounts')));
      expect(find.byKey(const Key('section-accounts')), findsOneWidget);
      await click(find.text('添加账号'));
      expect(calls.where((c) => c != 'codexAccountsStatus'), isEmpty);
      final platform = find.descendant(
        of: find.byType(FDialog),
        matching: find.text('Codex'),
      );
      await click(platform);
      expect(find.byKey(const Key('page-codex')), findsOneWidget);
      expect(calls.where((c) => c != 'codexAccountsStatus'), [
        'codexStartLogin',
      ]);
      expect(app.accounts.refreshes, 0);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
