import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/zcode_accounts_panel.dart';
import '../lib/zcode_activity_accounts.dart';
import '../lib/zcode_api.dart';
import 'memory_account_store.dart';
import 'zcode_activities_checks.dart' as fixture;

void main() {
  testWidgets(
    'known expiry with unknown balance stays visible and filterable',
    (tester) async {
      final store = MemoryAccountStore('expiry-panel');
      final owner = await fixture.account(store, fixture.FakeZcode());
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      (store.data['accounts'] as Map).values.single['buckets'] = [
        {
          'label': 'Expired',
          'unit': 'tokens',
          'remaining': 100,
          'expiresAt': now - 86400,
        },
        {
          'label': 'Empty',
          'unit': 'tokens',
          'remaining': 0,
          'expiresAt': now + 3600,
        },
        {
          'label': 'Unknown',
          'unit': 'tokens',
          'remaining': null,
          'expiresAt': now + 86400,
        },
        {
          'label': 'Later',
          'unit': 'tokens',
          'remaining': 30,
          'expiresAt': now + 172800,
        },
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ZcodeAccountsPanel(create: () => owner),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('7 天内到期'));
      await tester.pumpAndSettle();
      expect(find.text('Synthetic'), findsOneWidget);
      expect(find.textContaining('剩余未知'), findsOneWidget);
      expect(find.text('到期信息未知'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'rebind authorizes the selected account on a different saved device',
    (tester) async {
      const channel = MethodChannel('com.sailingloong.loongpass/files');
      var opened = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'zcodeRequestContext') return fixture.context;
            if (call.method == 'openZcodeAuthorization') {
              opened = true;
              return null;
            }
            throw StateError('Unexpected method');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final store = MemoryAccountStore('rebind-panel');
      final http = fixture.FakeZcode();
      final owner = await fixture.account(store, http);
      const replacement = '22222222-2222-4333-8444-666666666666';
      store.data['devicePool'] = [replacement];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ZcodeAccountsPanel(create: () => owner),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('account-${(await owner.accounts()).first.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新绑定设备'));
      await tester.pumpAndSettle();
      expect(opened, isTrue);
      expect(http.received.last.context['deviceMid'], replacement);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.textContaining('666666'), findsOneWidget);
      expect((store.data['accounts'] as Map).length, 1);
      expect(http.claims, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'manual verification receives public config and cancellation preserves rejection',
    (tester) async {
      const channel = MethodChannel('com.sailingloong.loongpass/files');
      var completeVerification = false, prompts = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'verifyZcodeClaim');
            expect(call.arguments, {
              'region': 'cn',
              'prefix': 'synthetic',
              'sceneId': 'scene',
            });
            prompts++;
            return completeVerification ? 'synthetic-proof' : null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final http = fixture.FakeZcode()
        ..claimCode = 3007
        ..claimHttp = 400
        ..acceptVerification = true;
      final owner = await fixture.account(
        MemoryAccountStore('captcha-panel'),
        http,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ZcodeAccountsPanel(create: () => owner),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('account-${(await owner.accounts()).first.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('核对并领取活动'));
      await tester.pumpAndSettle();
      expect(find.textContaining('需要验证码'), findsOneWidget);
      expect(prompts, 1);
      expect(http.claims, 1);
      completeVerification = true;
      await tester.tap(find.text('核对并领取活动'));
      await tester.pumpAndSettle();
      expect(find.text('已核对官方活动权益到账。'), findsOneWidget);
      expect(prompts, 2);
      expect(http.claims, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'restores activity accounts without consuming a reward during render',
    (tester) async {
      final store = MemoryAccountStore('panel');
      final http = fixture.FakeZcode();
      final previous = await fixture.account(store, http);
      previous.dispose();
      final owner = ZcodeActivityAccounts(
        store: store,
        api: ZcodeApi(http),
        now: () => fixture.now,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ZcodeAccountsPanel(create: () => owner),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Synthetic'), findsOneWidget);
      expect(find.text('授权智谱 BigModel 账号'), findsOneWidget);
      expect(find.textContaining('签到'), findsNothing);
      expect(find.textContaining('Z.AI'), findsNothing);
      expect(http.claims, 0);
      expect(http.balanceCalls, 0);
      await tester.tap(
        find.byKey(ValueKey('account-${(await owner.accounts()).first.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('检查活动与额度'));
      await tester.pumpAndSettle();
      expect(find.text('当前有可领取活动，尚未领取。'), findsOneWidget);
      expect(http.claims, 0);
      await tester.tap(find.text('核对并领取活动'));
      await tester.pumpAndSettle();
      expect(find.text('已核对官方活动权益到账。'), findsOneWidget);
      expect(http.claims, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'unavailable native platform does not advertise successful switching',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: ZcodeAccountsPanel()),
          ),
        ),
      );
      expect(find.textContaining('切换成功'), findsNothing);
      expect(find.textContaining('本次内存'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
