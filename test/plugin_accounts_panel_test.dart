import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/plugin_accounts.dart';
import '../lib/plugin_accounts_panel.dart';
import '../lib/plugin_rewards.dart';
import '../lib/plugin_runtime.dart';
import '../lib/plugin_sign_in_dialog.dart';
import '../lib/plugin_zcode_rewards.dart';
import '../lib/invitation_settings.dart';
import '../lib/managed_app.dart';

class _Runtime implements PluginRuntime {
  final calls = <(String, Map<String, Object?>)>[];
  bool auto = false, cancelled = false;
  Completer<Object?>? callback;
  @override
  Future<Object?> call(
    String method,
    Map<String, Object?> params, {
    Duration timeout = const Duration(seconds: 30),
    Future<void>? cancellation,
  }) async {
    calls.add((method, {...params}));
    if (method == 'prompt') {
      if (auto) return {'prompt': null};
      final inputs = params['inputs'] as Map;
      if (!inputs.containsKey('region'))
        return {
          'prompt': {
            'type': 'select',
            'key': 'region',
            'message': '区域',
            'options': [
              {'label': '国内', 'value': 'cn'},
              {'label': '海外', 'value': 'global'},
            ],
          },
        };
      if (!inputs.containsKey('password'))
        return {
          'prompt': {
            'type': 'password',
            'key': 'password',
            'message': '验证信息',
            'placeholder': '',
          },
        };
      return {'prompt': null};
    }
    if (method == 'validate') return {'error': null};
    if (method == 'authorize')
      return {
        'ok': true,
        'session': 'synthetic-session',
        'method': auto ? 'auto' : 'code',
        'url': 'https://fixture.invalid/authorize',
        'instructions': '请完成官方验证。',
      };
    if (method == 'callback') {
      if (!auto) return {'ok': true, 'account': 'fixture#signed'};
      callback = Completer<Object?>();
      cancellation?.then((_) {
        cancelled = true;
        if (!callback!.isCompleted)
          callback!.completeError(StateError('Cancelled'));
      });
      return callback!.future;
    }
    if (method == 'apiKey') return {'ok': true, 'account': 'fixture#key'};
    throw StateError('Unexpected native operation: $method');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Accounts extends ChangeNotifier implements PluginAccounts {
  _Accounts(
    this.runtime, {
    List<PluginAccount> rows = const [],
    Map<String, Map<String, dynamic>>? providers,
  }) : _rows = rows,
       providers =
           providers ??
           {
             'fixture': {
               'name': 'Fixture',
               'methods': [
                 {'type': 'api', 'label': 'API key'},
                 {'type': 'oauth', 'label': '官方账号'},
               ],
             },
           };
  @override
  final _Runtime runtime;
  @override
  final Map<String, Map<String, dynamic>> providers;
  List<PluginAccount> _rows;
  int refreshes = 0;
  bool failAutomatic = false;
  String? saved;
  @override
  String? error;
  @override
  List<PluginAccount> get accounts => _rows;
  @override
  Future<void> refresh() async {
    refreshes++;
  }

  @override
  Future<void> authorizationSaved(
    String key, {
    String? expectedRegistrationId,
  }) async {
    if (expectedRegistrationId != null) {
      expect(
        _rows.singleWhere((a) => a.key == key).registrationId,
        expectedRegistrationId,
      );
    }
    saved = key;
  }

  @override
  Future<void> setAutomatic(String key, bool enabled) async {
    if (failAutomatic) throw StateError('Synthetic save failure');
    _rows.singleWhere((a) => a.key == key).facts['automatic'] = enabled;
    notifyListeners();
  }

  @override
  Future<void> remove(String key) async {
    _rows = _rows.where((a) => a.key != key).toList();
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Rewards implements PluginRewards {
  _Rewards(this.accounts) : zcode = PluginZcodeRewards(accounts);
  @override
  final PluginAccounts accounts;
  @override
  final PluginZcodeRewards zcode;
  int claims = 0, refreshes = 0;
  bool failRefresh = false;
  @override
  Future<void> claim(String key, {bool automatic = false}) async {
    claims++;
  }

  @override
  Future<void> refresh(String key) async {
    refreshes++;
    if (failRefresh) throw StateError('Synthetic refresh failure');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const channel = MethodChannel('com.sailingloong.loongpass/files');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => throw PlatformException(code: 'open_failed'),
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final platform in [
    (
      app: ManagedApp.workbuddy,
      url: 'https://www.workbuddy.cn/events/invite/?inviteCode=custom-code',
    ),
    (
      app: ManagedApp.qoderCn,
      url: 'https://qoder.cn/activities?referral_code=custom-code',
    ),
  ]) {
    testWidgets(
      '${platform.app.label} browser account opens saved invitation before native sign-in',
      (tester) async {
        final runtime = _Runtime()..auto = true;
        final provider = platform.app.nativeProviders.single;
        final accounts = _Accounts(
          runtime,
          providers: {
            provider: {
              'name': platform.app.label,
              'methods': [
                {
                  'type': 'oauth',
                  'label': '${platform.app.label} account (browser)',
                },
              ],
            },
          },
        );
        final settings = InvitationSettings(platform.app);
        addTearDown(settings.dispose);
        addTearDown(accounts.dispose);
        final opened = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              opened.add((call.arguments as Map)['url'] as String);
              return null;
            });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PluginAccountsPanel(
                accounts: accounts,
                rewards: _Rewards(accounts),
                providerIds: {provider},
                title: platform.app.label,
                registrationUrl: () => settings.url,
              ),
            ),
          ),
        );
        await settings.save('custom-code');
        await tester.tap(find.text('添加账号'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('邀请注册'));
        await tester.pump();
        expect(opened, [platform.url]);
        expect(runtime.calls, isEmpty);
        await tester.tap(find.text('继续授权'));
        await tester.pump();
        await tester.pump();
        expect(
          runtime.calls.singleWhere((c) => c.$1 == 'authorize').$2['provider'],
          provider,
        );
        expect(opened.last, 'https://fixture.invalid/authorize');
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'invitation browser failure keeps direct authorization available',
    (tester) async {
      final runtime = _Runtime()..auto = true;
      final accounts = _Accounts(
        runtime,
        providers: {
          'workbuddy': {
            'name': 'WorkBuddy',
            'methods': [
              {'type': 'oauth', 'label': 'WorkBuddy account (browser)'},
            ],
          },
        },
      );
      addTearDown(accounts.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PluginSignInDialog(
              accounts: accounts,
              providerIds: const {'workbuddy'},
              title: '添加账号',
              registrationUrl: Uri.parse(
                'https://www.workbuddy.cn/events/invite/?inviteCode=custom',
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('邀请注册'));
      await tester.pumpAndSettle();
      expect(runtime.calls, isEmpty);
      expect(find.textContaining('未能打开浏览器'), findsOneWidget);
      await tester.tap(find.text('已有账号，直接授权'));
      await tester.pump();
      await tester.pump();
      expect(runtime.calls.any((c) => c.$1 == 'authorize'), isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('API-key entry bypasses invitation registration', (tester) async {
    final runtime = _Runtime()..auto = true;
    final accounts = _Accounts(runtime);
    addTearDown(accounts.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PluginSignInDialog(
            accounts: accounts,
            providerIds: const {'fixture'},
            title: '添加账号',
            registrationUrl: Uri.parse(
              'https://www.workbuddy.cn/events/invite/?inviteCode=custom',
            ),
          ),
        ),
      ),
    );
    expect(find.text('邀请注册'), findsNothing);
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('plugin-auth-input')), findsOneWidget);
    expect(runtime.calls.any((c) => c.$1 == 'authorize'), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'target reauthorization uses native capability without choosing a login method',
    (tester) async {
      final runtime = _Runtime()..auto = true;
      final target = PluginAccount(
        key: 'zcode#one',
        active: true,
        models: const [],
        facts: {
          'provider': 'zcode',
          'uid': 'official-a',
          'realm': 'bigmodel',
          'label': 'Saved account',
          'registrationId': 'existing',
        },
      );
      final accounts = _Accounts(
        runtime,
        rows: [target],
        providers: {
          'zcode': {
            'name': 'ZCode',
            'reauthorize': true,
            'methods': <dynamic>[],
          },
        },
      );
      final frozen = <String, String>{
        'device': '11111111-2222-4333-8444-555555555555',
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<String>(
                  context: context,
                  builder: (_) => PluginSignInDialog(
                    accounts: accounts,
                    providerIds: const {'zcode'},
                    title: '更新授权',
                    target: target,
                    registrationUrl: Uri.parse(
                      'https://www.workbuddy.cn/events/invite/?inviteCode=custom',
                    ),
                    authorizationContext: frozen,
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(runtime.calls, isEmpty);
      expect(find.byKey(const ValueKey('plugin-auth-method')), findsNothing);
      frozen['device'] = '22222222-2222-4333-8444-555555555555';
      await tester.tap(find.text('继续'));
      await tester.pump();
      await tester.pump();
      final auth = runtime.calls.singleWhere((c) => c.$1 == 'authorize').$2;
      expect(auth['account'], 'zcode#one');
      expect(auth.containsKey('method'), false);
      expect(auth['context'], {
        'expectedUid': 'official-a',
        'expectedRealm': 'bigmodel',
        'device': '11111111-2222-4333-8444-555555555555',
      });
      expect(runtime.calls.any((c) => c.$1 == 'prompt'), false);
      runtime.callback!.complete({'ok': true, 'account': target.key});
      await tester.pumpAndSettle();
      expect(accounts.saved, target.key);
      await tester.pumpWidget(const SizedBox());
      accounts.dispose();
    },
  );

  testWidgets(
    'details keep native amounts exact, isolate gifts, and only refresh pending claims',
    (tester) async {
      final expiry =
          DateTime.now().add(const Duration(days: 2)).millisecondsSinceEpoch ~/
          1000;
      final runtime = _Runtime();
      final accounts = _Accounts(
        runtime,
        rows: [
          PluginAccount(
            key: 'zcode#one',
            active: true,
            models: const [],
            facts: {
              'provider': 'zcode',
              'uid': 'verified-user',
              'realm': 'bigmodel',
              'label': 'Saved account',
              'registrationId': 'one',
              'automatic': true,
              'reward': {
                'status': 'pending',
                'checkedAt': 1793900000000,
                'claims': {
                  'night': {'state': 'pending', 'previous': []},
                },
                'buckets': [
                  {
                    'label': 'Gift tokens',
                    'unit': 'tokens',
                    'remaining': 12345678.0,
                    'expiresAt': expiry,
                  },
                ],
              },
            },
            usage: {
              'plan': 'GLM Coding Lite',
              'error': '',
              'windows': [
                {
                  'name': 'Coding credits',
                  'amount': 99999.125,
                  'limit': 100000,
                  'balance': 0.875,
                  'unit': 'credits',
                  'display': '100k / 100k',
                  'runsOut': 0.875,
                  'runsOutAt': DateTime.fromMillisecondsSinceEpoch(
                    expiry * 1000,
                    isUtc: true,
                  ).toIso8601String(),
                },
              ],
            },
            queriedAt: DateTime.utc(2026, 11, 8, 10),
          ),
        ],
      );
      final rewards = _Rewards(accounts);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PluginAccountsPanel(
                accounts: accounts,
                rewards: rewards,
                providerIds: const {'zcode'},
                title: 'ZCode',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          RegExp(r'^12345678 tokens / 0\.875 credits ·.*到期$'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('account-zcode#one')));
      await tester.pumpAndSettle();
      expect(find.textContaining('verified-user'), findsWidgets);
      expect(find.textContaining('bigmodel'), findsWidgets);
      expect(find.textContaining('99999.125'), findsWidgets);
      expect(find.textContaining('100000'), findsWidgets);
      expect(find.textContaining('0.875'), findsWidgets);
      expect(find.textContaining('12345678 tokens'), findsWidgets);
      expect(find.textContaining('Start Plan'), findsWidgets);
      expect(find.textContaining('GLM Coding Lite'), findsWidgets);
      expect(find.text('最近一次官方额度查询未完成。'), findsNothing);
      expect(accounts.refreshes, 0);
      expect(rewards.refreshes, 0);
      expect(runtime.calls, isEmpty);
      await tester.ensureVisible(find.text('核验领取结果'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('核验领取结果'));
      await tester.pumpAndSettle();
      expect(rewards.refreshes, 1);
      expect(rewards.claims, 0);
      rewards.failRefresh = true;
      await tester.ensureVisible(find.text('刷新额度'));
      await tester.tap(find.text('刷新额度'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('操作未完成'),
        ),
        findsOneWidget,
      );
      accounts.failAutomatic = true;
      await tester.ensureVisible(find.byType(Switch));
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('操作未完成'),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      accounts.dispose();
    },
  );

  testWidgets(
    'native prompts preserve method index and show browser failures before manual completion',
    (tester) async {
      final runtime = _Runtime();
      final nativeAccounts = _Accounts(runtime);
      final completed = Completer<String?>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => completed.complete(
                  await showDialog<String>(
                    context: context,
                    builder: (_) => PluginSignInDialog(
                      accounts: nativeAccounts,
                      providerIds: const {'fixture'},
                      title: '添加账号',
                    ),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(runtime.calls, isEmpty);
      await tester.tap(find.byKey(const Key('plugin-auth-method')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('官方账号').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('plugin-auth-prompt-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('海外').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('plugin-auth-input'));
      expect(tester.widget<TextField>(input).obscureText, true);
      await tester.enterText(input, 'synthetic-secret');
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();
      expect(find.textContaining('未能打开浏览器'), findsOneWidget);
      expect(find.text('复制授权链接'), findsOneWidget);
      expect(nativeAccounts.saved, null);
      expect(
        runtime.calls.where((c) => c.$1 == 'authorize').single.$2['method'],
        1,
      );
      expect(
        runtime.calls.where((c) => c.$1 == 'authorize').single.$2['inputs'],
        {'region': 'global', 'password': 'synthetic-secret'},
      );
      await tester.enterText(
        find.byKey(const Key('plugin-auth-input')),
        'official-code',
      );
      await tester.tap(find.text('完成授权'));
      await tester.pumpAndSettle();
      expect(await completed.future, 'fixture#signed');
      expect(nativeAccounts.saved, 'fixture#signed');
      expect(
        runtime.calls.where((c) => c.$1 == 'callback').single.$2['code'],
        'official-code',
      );
      await tester.pumpWidget(const SizedBox());
      nativeAccounts.dispose();
    },
  );

  testWidgets('disposing an automatic sign-in cancels its owned callback', (
    tester,
  ) async {
    final runtime = _Runtime()..auto = true;
    final accounts = _Accounts(
      runtime,
      providers: {
        'fixture': {
          'name': 'Fixture',
          'methods': [
            {'type': 'oauth', 'label': '官方账号'},
          ],
        },
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PluginSignInDialog(
          accounts: accounts,
          providerIds: const {'fixture'},
          title: '添加账号',
        ),
      ),
    );
    await tester.tap(find.text('继续'));
    await tester.pump();
    await tester.pump();
    expect(runtime.callback, isNotNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(runtime.cancelled, true);
    expect(accounts.saved, null);
    accounts.dispose();
  });

  testWidgets('cancel stops the callback before the dialog closing animation', (
    tester,
  ) async {
    final runtime = _Runtime()..auto = true;
    final accounts = _Accounts(
      runtime,
      providers: {
        'fixture': {
          'name': 'Fixture',
          'methods': [
            {'type': 'oauth', 'label': '官方账号'},
          ],
        },
      },
    );
    final completed = Completer<String?>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => completed.complete(
                await showDialog<String>(
                  context: context,
                  builder: (_) => PluginSignInDialog(
                    accounts: accounts,
                    providerIds: const {'fixture'},
                    title: '添加账号',
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    try {
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续'));
      await tester.pump();
      expect(runtime.callback, isNotNull);
      await tester.tap(find.text('取消'));
      await tester.pump();
      expect(runtime.cancelled, true);
      expect(await completed.future, null);
      expect(accounts.saved, null);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      accounts.dispose();
    }
  });

  testWidgets(
    'API authorization masks the key and preserves the native method',
    (tester) async {
      final runtime = _Runtime()..auto = true;
      final accounts = _Accounts(runtime);
      final completed = Completer<String?>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => completed.complete(
                  await showDialog<String>(
                    context: context,
                    builder: (_) => PluginSignInDialog(
                      accounts: accounts,
                      providerIds: const {'fixture'},
                      title: '添加账号',
                    ),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('plugin-auth-input'));
      expect(tester.widget<TextField>(input).obscureText, true);
      await tester.enterText(input, 'synthetic-api-key');
      await tester.tap(find.text('完成授权'));
      await tester.pumpAndSettle();
      expect(await completed.future, 'fixture#key');
      expect(accounts.saved, 'fixture#key');
      final sent = runtime.calls.where((c) => c.$1 == 'apiKey').single.$2;
      expect(sent['method'], 0);
      expect(sent['key'], 'synthetic-api-key');
      expect(runtime.calls.any((c) => c.$1 == 'authorize'), false);
      await tester.pumpWidget(const SizedBox());
      accounts.dispose();
    },
  );

  testWidgets(
    'desktop applied result asks for real client identity verification',
    (tester) async {
      final accounts = _Accounts(
        _Runtime(),
        rows: [
          PluginAccount(
            key: 'workbuddy#one',
            active: true,
            models: const [],
            facts: {
              'provider': 'workbuddy',
              'uid': 'official-user',
              'realm': 'www.workbuddy.cn',
              'label': 'Desktop account',
              'registrationId': 'one',
              'automatic': false,
            },
          ),
        ],
      );
      final rewards = _Rewards(accounts);
      String? activated;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PluginAccountsPanel(
                accounts: accounts,
                rewards: rewards,
                providerIds: const {'workbuddy'},
                title: 'WorkBuddy',
                activate: (key) async {
                  activated = key;
                  return 'applied';
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account-workbuddy#one')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('切换客户端账号'));
      await tester.tap(find.text('切换客户端账号'));
      await tester.pumpAndSettle();
      expect(activated, 'workbuddy#one');
      expect(find.textContaining('请打开 WorkBuddy 核对当前身份'), findsWidgets);
      expect(find.textContaining('切换成功'), findsNothing);
      final browser = accounts.accounts.single;
      accounts._rows = [
        browser,
        PluginAccount(
          key: 'workbuddy#two',
          facts: {
            ...browser.facts,
            'label': 'Other account',
            'uid': 'other-user',
            'registrationId': 'two',
          },
          active: true,
          models: const [],
        ),
      ];
      accounts.notifyListeners();
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account-workbuddy#two')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('请打开 WorkBuddy 核对当前身份'),
        ),
        findsNothing,
      );
      accounts._rows = [
        PluginAccount(
          key: browser.key,
          facts: browser.facts,
          active: true,
          models: const [],
          source: 'desktop',
        ),
      ];
      accounts.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('切换客户端账号'), findsNothing);
      expect(accounts.refreshes, 0);
      await tester.pumpWidget(const SizedBox());
      accounts.dispose();
    },
  );
}
