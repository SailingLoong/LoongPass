import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/rewards/reward_accounts.dart';
import '../lib/rewards/reward_accounts_panel.dart';
import '../lib/rewards/reward_provider.dart';
import 'reward_test_support.dart';

void main() {
  testWidgets(
    'saved account shows real balance and an unknown claim is reconciled without replay',
    (tester) async {
      final store = MemoryStore(),
          provider = Provider('test')..loseReply = true;
      final owner = RewardAccounts(
        store: store,
        providers: [provider],
        transportFor: (_) => NoNetwork(),
      );
      addTearDown(owner.dispose);
      await owner.restore();
      await owner.beginLogin('test');
      await owner.completeLogin();
      await owner.claim('test', provider.identity);
      final reads = provider.reads;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RewardAccountsPanel(provider: provider, owner: owner),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('125.5'), findsWidgets);
      expect(provider.reads, reads);
      await tester.tap(find.text('Test account'));
      await tester.pumpAndSettle();
      expect(find.textContaining('结果待核对'), findsWidgets);
      await tester.tap(find.text('核对并领取'));
      await tester.pumpAndSettle();
      expect(provider.claims, 1);
      expect(owner.accountsFor('test').single.outcome, 'unknown');
      expect(find.textContaining('结果待核对'), findsWidgets);
    },
  );

  testWidgets(
    'in-flight authorization can be cancelled from its visible control',
    (tester) async {
      final provider = Provider('test');
      final flow = Login(null)..wait = Completer<RewardSession?>();
      provider.login = flow;
      final owner = RewardAccounts(
        store: MemoryStore(),
        providers: [provider],
        transportFor: (_) => NoNetwork(),
      );
      addTearDown(owner.dispose);
      await owner.restore();
      await owner.beginLogin('test');
      final pending = owner.completeLogin();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RewardAccountsPanel(provider: provider, owner: owner),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('取消授权'));
      final cancelled = owner.loginProvider == null;
      flow.wait!.complete(
        RewardSession(
          identity: 'late',
          label: 'Late',
          credentials: {'token': 'synthetic'},
        ),
      );
      await pending;
      expect(cancelled, isTrue);
      expect(owner.accountsFor('test'), isEmpty);
    },
  );
}
