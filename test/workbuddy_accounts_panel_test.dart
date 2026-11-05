import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/workbuddy_accounts_panel.dart';
import '../lib/workbuddy_account_flow.dart';
import '../tool/workbuddy_flow_checks.dart' as synthetic;
import '../tool/workbuddy_single_checks.dart' as single;

// Written for Mac/Flutter validation. Not executed in this cloud task because
// prior Flutter test operations were denied; no alternate route was attempted.
void main() {
  testWidgets('official authorization completes and saves without another button press', (tester) async {
    final server = single.Server('synthetic-single-account');
    final saved = single.VaultStore();
    final nativeCalls = <String>[];
    const channel = MethodChannel('com.sailingloong.loongpass/files');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call.method);
      final args = Map<String, Object?>.from(call.arguments as Map);
      switch (call.method) {
        case 'listWorkBuddyVaultKeys':
          return saved.rows.keys.toList();
        case 'readWorkBuddyVault':
          return saved.read(args['key'] as String);
        case 'compareExchangeWorkBuddyVault':
          return saved.compareExchange(args['key'] as String, args['expected'] as int?,
            Map<String, Object?>.from(args['value'] as Map));
        default:
          throw StateError('Unexpected native operation');
      }
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: WorkBuddyAccountsPanel(
        savedSingleAccount: true,
        create: () => WorkBuddyAccountFlow.inMemory(exchange: server, store: synthetic.MemoryStore()),
        openAuthorization: (_) async {},
      ),
    ))));
    await tester.tap(find.byKey(const Key('workbuddy-login')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('继续官方授权'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('workbuddy-poll')), findsNothing);
    expect(find.text('synthetic-single-account'), findsOneWidget,
      reason: '${nativeCalls.join(', ')}\nrows ${saved.rows.length}\nrequests ${server.requests.map((r) => r.uri.path).join(', ')}\n'
        '${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).join('\n')}');
    expect(saved.rows, hasLength(1));
    expect(server.posts, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
    expect(find.textContaining('真实授权、保存恢复及签到仍等待'), findsOneWidget);
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
    expect(find.text('synthetic-user'), findsOneWidget);
    await tester.tap(find.byKey(const Key('workbuddy-claim')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('核对并签到一次'));
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
