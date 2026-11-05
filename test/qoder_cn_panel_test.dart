import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loongpass/qoder_device_accounts.dart';
import 'package:loongpass/qoder_device_panel.dart';

void main() {
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
    Map<String, dynamic>? body,
  ) => throw StateError('Unexpected network call');
}
