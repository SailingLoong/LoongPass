import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/minimax_accounts.dart';
import '../lib/minimax_accounts_panel.dart';
import '../lib/minimax_http.dart';
import 'memory_account_store.dart';

void main() {
  testWidgets('unsupported platform clearly disables authorization', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: MiniMaxAccountsPanel())),
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('minimax-login')))
          .onPressed,
      isNull,
    );
    expect(find.text('账号授权目前仅支持 macOS。'), findsOneWidget);
  });
  testWidgets(
    'startup restores the account owner once and preserves regional label',
    (tester) async {
      var opens = 0;
      final owner = MiniMaxAccounts(
        store: MiniMaxAccountStore(MemoryAccountStore('MiniMax-global')),
        http: _NoNetwork(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MiniMaxAccountsPanel(
              region: 'global',
              open: () async {
                opens++;
                return owner;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(opens, 1);
      expect(find.text('授权 MiniMax 账号'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('minimax-login')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('刷新已保存账号'));
      await tester.pumpAndSettle();
      expect(opens, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class _NoNetwork extends MiniMaxHttp {
  @override
  Future<MiniMaxReply> send(
    MiniMaxEndpoint e, {
    required String accessToken,
    required String region,
    String? userId,
    bool Function()? isCurrent,
  }) => throw StateError('Unexpected network call');
}
