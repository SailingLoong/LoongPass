import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loongpass/qoder_device_accounts.dart';
import 'package:loongpass/qoder_device_panel.dart';
import 'package:loongpass/qoder_credits.dart';
import 'package:loongpass/credit_summary.dart';
import 'package:loongpass/compact_accounts_table.dart';

void main() {
  testWidgets(
    'Qoder token pools keep their units in balance and expiry views',
    (tester) async {
      final owner = _QuotaOwner();
      addTearDown(owner.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QoderDeviceAccountsPanel(owner: owner)),
        ),
      );
      await tester.pumpAndSettle();
      final row = tester
          .widget<CompactAccountsTable>(find.byType(CompactAccountsTable))
          .entries
          .single;
      expect(row.balance, '套餐 500000 tokens / 附加 855 积分');
      expect(row.upcomingExpiryText, startsWith('8 tokens · '));
      expect(row.upcomingExpiryText, isNot(contains('积分')));
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final terminal in ['completed', 'unknown']) {
    testWidgets('cancel presents actual native commit outcome $terminal', (
      tester,
    ) async {
      const channel = MethodChannel('com.sailingloong.loongpass/files');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QoderDeviceAccountsPanel(
              create: () => _TerminalOwner(terminal),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('qoder-login')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消授权'));
      await tester.pumpAndSettle();
      expect(find.text('本次授权已取消。'), findsNothing);
      expect(
        find.textContaining(terminal == 'completed' ? '授权已先完成保存' : '不能确认取消'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('unsupported platform keeps login disabled', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: QoderDeviceAccountsPanel())),
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('qoder-login')))
          .onPressed,
      isNull,
    );
    expect(find.text('账号授权目前仅支持 macOS。'), findsOneWidget);
  });
}

class _QuotaOwner extends QoderDeviceAccounts {
  _QuotaOwner()
    : super(native: _NoNative(), transport: _NoNetwork(), nowMs: () => 0);
  @override
  Future<List<QoderSavedAccount>> accountViews() async => [
    const QoderSavedAccount('units', 'Unit account', false, 0, null),
  ];
  @override
  QoderCredits? credits(String uid) => QoderCredits(
    CreditSummary(null, 0, DateTime.utc(2026, 11, 8), [
      CreditExpiry(DateTime.utc(2030), 8),
    ]),
    500000,
    855,
    planUnit: 'tokens',
    addOnUnit: 'credits',
    packagesUnit: 'tokens',
  );
}

class _TerminalOwner extends QoderDeviceAccounts {
  _TerminalOwner(this.terminal)
    : super(native: _NoNative(), transport: _NoNetwork(), nowMs: () => 0);
  final String terminal;
  bool pending = false;
  @override
  bool get loginPending => pending;
  @override
  Future<List<QoderSavedAccount>> accountViews() async => [];
  @override
  Future<QoderLogin> startLogin() async {
    pending = true;
    return QoderLogin(Uri.https('qoder.cn', '/device/selectAccounts'));
  }

  @override
  void followAuthorization() {}
  @override
  Future<String> cancelLogin() async {
    pending = false;
    return terminal;
  }
}

class _NoNative implements QoderNative {
  @override
  Future<Map<String, dynamic>> call(String method, Map<String, dynamic> args) =>
      throw StateError('Unexpected native call');
}

class _NoNetwork implements QoderTransport {
  @override
  Future<QoderResponse> send(
    String method,
    Uri url,
    String? bearer,
    Map<String, dynamic>? body, {
    bool Function()? isCurrent,
  }) => throw StateError('Unexpected network call');
}
