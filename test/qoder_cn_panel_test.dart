import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:loongpass/qoder_cn.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loongpass/qoder_cn_panel.dart';

void main() {
  for (final terminal in ['completed', 'unknown']) {
    testWidgets('cancel preserves $terminal instead of claiming cancellation', (tester) async {
      const channel = MethodChannel('com.sailingloong.loongpass/files');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async => null);
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: QoderCnPanel(create: () => _TerminalOwner(terminal)))));
      await tester.tap(find.byKey(const Key('qoder-cn-login')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('授权并保存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消授权'));
      await tester.pumpAndSettle();
      expect(find.text('本次授权已取消。'), findsNothing);
      expect(find.textContaining(terminal == 'completed' ? '授权已先完成保存' : '不能确认取消'), findsOneWidget);
    });
  }

  testWidgets('real account controls stay disabled before native acceptance', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: QoderCnPanel())));
    final button = tester.widget<FilledButton>(find.byKey(const Key('qoder-cn-login')));
    expect(button.onPressed, isNull);
    expect(find.textContaining('原生验收未完成'), findsOneWidget);
  });

  testWidgets('CN page states limitations and does not initialize on render', (tester) async {
    var opens = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: QoderCnPanel(create: () {
      opens++;
      throw StateError('must not create on navigation');
    }))));
    expect(opens, 0);
    expect(find.textContaining('不切换 Qoder 桌面账号'), findsOneWidget);
    await tester.tap(find.byKey(const Key('qoder-cn-login')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(opens, 0);
  });
}

class _TerminalOwner extends QoderCn {
  _TerminalOwner(this.terminal) : super(native: _NoNative(), transport: _NoNetwork(), nowMs: () => 0);
  final String terminal;
  @override Future<CnLogin> startLogin() async => CnLogin(Uri.https('qoder.cn', '/device/selectAccounts'));
  @override Future<String> cancelLogin() async => terminal;
}
class _NoNative implements CnNative {
  @override Future<Map<String, dynamic>> call(String method, Map<String, dynamic> args) => throw StateError('unexpected native operation');
}
class _NoNetwork implements CnTransport {
  @override Future<CnResponse> send(String method, Uri url, String? bearer, Map<String, dynamic>? body) => throw StateError('unexpected network operation');
}
