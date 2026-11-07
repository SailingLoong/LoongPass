import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/codex_accounts.dart';

const _channel = MethodChannel('test.loongpass/codex');

Map<String, Object?> snapshot({
  String? currentId = 'official-a',
  bool available = true,
  bool busy = false,
  bool loginPending = false,
  String? issue,
  String? message,
  String? outcome,
}) => {
  'available': available,
  if (issue != null) 'issue': issue,
  'accounts': [
    {
      'id': 'official-a',
      'email': 'same@example.invalid',
      'workspaceId': 'workspace-a',
      'plan': 'plus',
    },
    {
      'id': 'official-b',
      'email': 'same@example.invalid',
      'workspaceId': 'workspace-b',
      'plan': 'team',
    },
  ],
  if (currentId != null) 'currentId': currentId,
  'loginPending': loginPending,
  'busy': busy,
  if (message != null) 'message': message,
  'observedAt': '2026-11-07T08:15:00Z',
  if (outcome != null) 'outcome': outcome,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  test(
    'snapshot retains workspace identities and discards credential fields',
    () {
      final raw = snapshot()
        ..['access_token'] = 'synthetic-top-secret'
        ..['credentials'] = {'refresh_token': 'synthetic-refresh-secret'};
      (raw['accounts'] as List).first['id_token'] = 'synthetic-id-secret';
      final state = CodexAccountsSnapshot.fromNative(raw);
      expect(state.accounts.map((a) => a.id), ['official-a', 'official-b']);
      expect(state.accounts.map((a) => a.workspaceId), [
        'workspace-a',
        'workspace-b',
      ]);
      expect(state.currentId, 'official-a');
      expect(state.observedAt, DateTime.utc(2026, 11, 7, 8, 15));
      final encoded = jsonEncode(state.toJson());
      expect(encoded, isNot(contains('token')));
      expect(encoded, isNot(contains('secret')));
      expect(encoded, isNot(contains('credentials')));
      expect(
        CodexAccountsSnapshot.fromNative(
          jsonDecode(encoded),
        ).accounts.last.plan,
        'team',
      );
    },
  );

  test('status loads and reads only the native projection', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return snapshot();
    });
    final accounts = CodexAccounts(
      channel: _channel,
      platform: TargetPlatform.macOS,
    );
    addTearDown(accounts.dispose);
    await accounts.refreshSnapshot();
    await accounts.refreshSnapshot();
    expect(accounts.available, isTrue);
    expect(accounts.snapshot.currentId, 'official-a');
    expect(calls.map((c) => c.method), [
      'codexAccountsStatus',
      'codexAccountsStatus',
    ]);
    expect(calls.every((c) => c.arguments == null), isTrue);
  });

  test(
    'explicit actions send only opaque ids and show distinct activation outcomes',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return snapshot(
          currentId: call.method == 'codexActivate'
              ? 'official-b'
              : 'official-a',
          outcome: call.method == 'codexActivate' ? 'opened' : null,
          loginPending: call.method == 'codexStartLogin',
        );
      });
      final accounts = CodexAccounts(
        channel: _channel,
        platform: TargetPlatform.macOS,
      );
      addTearDown(accounts.dispose);
      await accounts.refreshSnapshot();
      await accounts.importCurrent();
      await accounts.startLogin();
      expect(accounts.snapshot.loginPending, isTrue);
      await accounts.cancelLogin();
      await accounts.activate('official-b');
      expect(accounts.snapshot.currentId, 'official-b');
      expect(accounts.snapshot.outcome, CodexActivationOutcome.opened);
      await accounts.remove('official-a');
      expect(calls.map((c) => c.method), [
        'codexAccountsStatus',
        'codexImportCurrent',
        'codexStartLogin',
        'codexCancelLogin',
        'codexActivate',
        'codexRemove',
      ]);
      expect(calls.take(4).every((c) => c.arguments == null), isTrue);
      expect(calls[4].arguments, {'id': 'official-b'});
      expect(calls[5].arguments, {'id': 'official-a'});
    },
  );

  test(
    'in-flight actions and native busy state prevent conflicting mutations',
    () async {
      final pending = Completer<Map<String, Object?>>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call.method);
        return call.method == 'codexImportCurrent'
            ? pending.future
            : snapshot();
      });
      final accounts = CodexAccounts(
        channel: _channel,
        platform: TargetPlatform.macOS,
      );
      addTearDown(accounts.dispose);
      await accounts.refreshSnapshot();
      final importing = accounts.importCurrent();
      expect(accounts.busy, isTrue);
      await accounts.startLogin();
      await accounts.activate('official-b');
      await accounts.remove('official-a');
      pending.complete(snapshot(busy: true));
      await importing;
      expect(accounts.canMutate, isFalse);
      await accounts.startLogin();
      expect(calls, ['codexAccountsStatus', 'codexImportCurrent']);
    },
  );

  test(
    'pending login allows cancellation even when native owner is busy',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call.method);
        return snapshot(
          loginPending: call.method != 'codexCancelLogin',
          busy: call.method != 'codexCancelLogin',
        );
      });
      final accounts = CodexAccounts(
        channel: _channel,
        platform: TargetPlatform.macOS,
      );
      addTearDown(accounts.dispose);
      await accounts.refreshSnapshot();
      await accounts.importCurrent();
      await accounts.startLogin();
      await accounts.cancelLogin();
      expect(calls, ['codexAccountsStatus', 'codexCancelLogin']);
      expect(accounts.snapshot.loginPending, isFalse);
    },
  );

  test(
    'native exceptions and malformed responses fail closed without diagnostic secrets',
    () async {
      messenger.setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'codexAccountsStatus') return snapshot();
        throw PlatformException(
          code: 'synthetic-secret',
          message: 'Bearer synthetic-token',
          details: {'auth': 'synthetic-private'},
        );
      });
      final accounts = CodexAccounts(
        channel: _channel,
        platform: TargetPlatform.macOS,
      );
      addTearDown(accounts.dispose);
      await accounts.refreshSnapshot();
      await accounts.importCurrent();
      expect(accounts.error, isNotNull);
      expect(accounts.error, isNot(contains('synthetic')));
      expect(accounts.error, isNot(contains('token')));
      expect(accounts.canMutate, isFalse);
      messenger.setMockMethodCallHandler(
        _channel,
        (_) async => {'access_token': 'synthetic-private'},
      );
      await accounts.refreshSnapshot();
      expect(accounts.available, isFalse);
      expect(accounts.error, isNot(contains('synthetic')));
    },
  );

  test(
    'unsupported platform never falls through to native mutations',
    () async {
      var nativeCalls = 0;
      messenger.setMockMethodCallHandler(_channel, (_) async {
        nativeCalls++;
        return snapshot();
      });
      final accounts = CodexAccounts(
        channel: _channel,
        platform: TargetPlatform.windows,
      );
      addTearDown(accounts.dispose);
      await accounts.start();
      await accounts.refreshSnapshot();
      await accounts.importCurrent();
      await accounts.startLogin();
      await accounts.activate('official-a');
      await accounts.remove('official-a');
      expect(accounts.snapshot.issue, CodexAccountsIssue.unsupportedPlatform);
      expect(accounts.available, isFalse);
      expect(nativeCalls, 0);
    },
  );

  test(
    'older status response cannot replace a completed explicit action',
    () async {
      final stale = Completer<Map<String, Object?>>();
      var reads = 0;
      messenger.setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'codexAccountsStatus' && ++reads == 2)
          return stale.future;
        return snapshot(
          currentId: call.method == 'codexActivate'
              ? 'official-b'
              : 'official-a',
        );
      });
      final accounts = CodexAccounts(
        channel: _channel,
        platform: TargetPlatform.macOS,
      );
      addTearDown(accounts.dispose);
      await accounts.refreshSnapshot();
      final status = accounts.refreshSnapshot();
      await accounts.activate('official-b');
      stale.complete(snapshot());
      await status;
      expect(accounts.snapshot.currentId, 'official-b');
    },
  );

  testWidgets(
    'root-lifetime polling observes completion without starting authentication',
    (tester) async {
      final calls = <String>[];
      var reads = 0;
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call.method);
        return snapshot(currentId: ++reads == 1 ? 'official-a' : 'official-b');
      });
      final accounts = CodexAccounts(
        channel: _channel,
        platform: TargetPlatform.macOS,
      );
      await accounts.start();
      await tester.pump(const Duration(seconds: 2));
      expect(accounts.snapshot.currentId, 'official-b');
      accounts.dispose();
      await tester.pump(const Duration(seconds: 4));
      expect(calls, ['codexAccountsStatus', 'codexAccountsStatus']);
    },
  );

  test(
    'disposal ignores late snapshots without cancelling native authorization',
    () async {
      final pending = Completer<Map<String, Object?>>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call.method);
        return pending.future;
      });
      final accounts = CodexAccounts(
        channel: _channel,
        platform: TargetPlatform.macOS,
      );
      var changes = 0;
      accounts.addListener(() => changes++);
      final loading = accounts.start();
      accounts.dispose();
      final previous = changes;
      pending.complete(snapshot(loginPending: true));
      await loading;
      expect(changes, previous);
      expect(calls, ['codexAccountsStatus']);
    },
  );
}
