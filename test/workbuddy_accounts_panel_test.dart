import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loongpass/workbuddy_accounts_panel.dart';
import 'package:loongpass/workbuddy_account_flow.dart';
import '../tool/workbuddy_flow_checks.dart' as synthetic;

// Written for Mac/Flutter validation. Not executed in this cloud task because
// prior Flutter test operations were denied; no alternate route was attempted.
void main() {
  testWidgets('late async owner is retired after page disposal without authorization traffic', (tester) async {
    final pending=Completer<WorkBuddyAccountFlow>();
    final exchange=synthetic.SyntheticExchange();
    final flow=synthetic.owner(exchange,synthetic.MemoryStore());
    var opened=0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WorkBuddyAccountsPanel(
      create:()=>pending.future,openAuthorization:(_) async {opened++;},
    ))));
    await tester.tap(find.byKey(const Key('workbuddy-login')));
    // Busy progress continues behind the modal until its action is chosen.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('继续官方授权'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(flow);
    await tester.pump();
    expect(await flow.begin(),isNull);
    expect(exchange.requests,0);
    expect(opened,0);
    expect(tester.takeException(),isNull);
  });

  testWidgets('partial injected dependencies never fall through to real production operations', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WorkBuddyAccountsPanel(
      create:()=>throw StateError('must not create'),
    ))));
    expect(tester.widget<FilledButton>(find.byKey(const Key('workbuddy-login'))).onPressed,isNull);
  });

  testWidgets('default controls remain unavailable before native validation', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: WorkBuddyAccountsPanel())));
    final login = tester.widget<FilledButton>(find.byKey(const Key('workbuddy-login')));
    expect(login.onPressed, isNull);
    expect(find.textContaining('Mac 原生验收未完成'), findsOneWidget);
    expect(find.textContaining('不切换 WorkBuddy 桌面账号'), findsOneWidget);
  });

  testWidgets('render and cancelled authorization create no owner or browser', (tester) async {
    var created = 0, opened = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WorkBuddyAccountsPanel(
      create: () { created++; return synthetic.owner(synthetic.SyntheticExchange(), synthetic.MemoryStore()); },
      openAuthorization: (_) async { opened++; },
    ))));
    expect(created, 0);
    await tester.tap(find.byKey(const Key('workbuddy-login')));
    // Busy progress continues behind the modal until its action is chosen.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(created, 0);
    expect(opened, 0);
  });

  testWidgets('unknown receipt stays visible after status refresh without retry', (tester) async {
    final exchange = synthetic.SyntheticExchange()..loseReceipt = true;
    final store = synthetic.MemoryStore();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WorkBuddyAccountsPanel(
      create: () => synthetic.owner(exchange, store), openAuthorization: (_) async {},
    ))));
    await tester.tap(find.byKey(const Key('workbuddy-login')));
    // Busy progress continues behind the modal until its action is chosen.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('继续官方授权'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workbuddy-poll')));
    await tester.pumpAndSettle();
    expect(find.text('synthetic-user'), findsOneWidget);
    await tester.tap(find.byKey(const Key('workbuddy-claim')));
    await tester.pumpAndSettle();
    expect(find.textContaining('本次结果未知'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byKey(const Key('workbuddy-claim'))).onPressed, isNull);
    await tester.tap(find.byKey(const Key('workbuddy-status')));
    await tester.pumpAndSettle();
    expect(find.textContaining('本次结果未知'), findsOneWidget);
    expect(find.textContaining('已核实本次到账'), findsNothing);
    expect(exchange.posts, 1);
    expect(store.row, isNotNull);
  });

  testWidgets('failed browser open cancels memory authorization', (tester) async {
    final exchange = synthetic.SyntheticExchange();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WorkBuddyAccountsPanel(
      create: () => synthetic.owner(exchange, synthetic.MemoryStore()),
      openAuthorization: (_) async => throw StateError('synthetic-secret'),
    ))));
    await tester.tap(find.byKey(const Key('workbuddy-login')));
    // Busy progress continues behind the modal until its action is chosen.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('继续官方授权'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('workbuddy-poll')), findsNothing);
    expect(find.textContaining('未能确认授权页已打开'), findsOneWidget);
    expect(find.textContaining('synthetic-secret'), findsNothing);
    expect(exchange.posts, 0);
  });
}
