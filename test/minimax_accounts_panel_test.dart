import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loongpass/minimax_accounts_panel.dart';

void main() {
  testWidgets('real account controls stay disabled before native acceptance', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: MiniMaxAccountsPanel())));
    final button = tester.widget<FilledButton>(find.byKey(const Key('minimax-import')));
    expect(button.onPressed, isNull);
    expect(find.textContaining('原生验收未完成'), findsOneWidget);
  });

  testWidgets('idle panel performs no account access', (tester) async {
    var opens = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      MiniMaxAccountsPanel(open: () async {
        opens++;
        throw StateError('must not initialize on navigation');
      }),
    )));
    expect(opens, 0);
    expect(find.textContaining('桌面凭证切换尚未实现'), findsOneWidget);
  });

  testWidgets('declined import confirmation never opens account service', (tester) async {
    var opens = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      MiniMaxAccountsPanel(open: () async {
        opens++;
        throw StateError('must not initialize after cancel');
      }),
    )));
    await tester.tap(find.byKey(const Key('minimax-import')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(opens, 0);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
