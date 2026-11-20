import 'desktop_test_app.dart';

import 'package:forui/forui.dart';

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/account_workspace_registry.dart';
import '../lib/workspace_accounts.dart';
import '../lib/plugin_accounts.dart';
import '../lib/credit_summary_view.dart';
import '../lib/compact_accounts_table.dart';
import '../lib/plugin_accounts_panel.dart';
import '../lib/plugin_rewards.dart';
import '../lib/plugin_runtime.dart';
import '../lib/plugin_sign_in_dialog.dart';
import '../lib/plugin_zcode_rewards.dart';
import '../lib/zcode_api.dart';
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
  bool failRefresh = false, refreshedUsage = false;
  Completer<void>? refreshGate;
  String? refreshedKey;
  @override
  Future<void> claim(
    String key, {
    Future<String?> Function(ZcodeCaptchaConfig)? verify,
  }) async {
    claims++;
  }

  @override
  bool supports(PluginAccount account) =>
      account.provider == 'zcode' ||
      accounts.providers[account.provider]?['checkin'] == true;

  @override
  Future<void> refresh(String key, {bool includeUsage = false}) async {
    refreshes++;
    refreshedKey = key;
    refreshedUsage = includeUsage;
    await refreshGate?.future;
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

  testDesktopWidgets(
    'reward journal shapes reach activity through the platform registry; verification only reads',
    (tester) async {
      PluginAccount snapshot(
        String id,
        String provider,
        Map<String, dynamic> reward, {
        String? error,
        String? uid,
      }) => PluginAccount(
        key: '$provider#$id',
        active: true,
        models: const [],
        error: error,
        facts: {
          'provider': provider,
          'uid': uid ?? id,
          'realm': 'cn',
          'label': id,
          'registrationId': id,
          'reward': reward,
        },
      );
      final accounts = _Accounts(
        _Runtime(),
        providers: {
          'qoder-cn': {'checkin': true, 'checkinStatus': true},
          'loomy': {'checkin': true},
          'trae-cn': {'checkin': false},
        },
        rows: [
          snapshot('submitted', 'qoder-cn', {
            'status': 'pending',
            'attemptId': 'attempt',
            'submittedAt': 123,
            'history': [],
          }),
          snapshot('observation', 'qoder-cn', {
            'status': 'unavailable',
            'outcome': 'unknown',
            'observedAt': 123,
            'history': [],
          }),
          snapshot('discovery', 'zcode', {
            'status': 'discoveryIncomplete',
            'claims': {},
          }),
          snapshot('shared-device', 'zcode', {'status': 'devicePending'}),
          snapshot('missing-device', 'zcode', {'status': 'device_required'}),
          snapshot('ineligible', 'qoder-cn', {
            'status': 'unavailable',
            'outcome': 'ineligible',
          }),
          snapshot('no-evidence', 'qoder-cn', {
            'status': 'unavailable',
            'history': [],
          }),
          snapshot('no-status-hook', 'loomy', {
            'status': 'unavailable',
            'outcome': 'unknown',
          }),
          snapshot('loomy-pending', 'loomy', {
            'status': 'pending',
            'attemptId': 'loomy-attempt',
          }),
          snapshot('not-a-reward-provider', 'trae-cn', {
            'status': 'unavailable',
            'outcome': 'unknown',
          }),
          snapshot('expired', 'qoder-cn', {
            'status': 'pending',
          }, error: 'authorization_required'),
          snapshot('missing-uid', 'qoder-cn', {'status': 'pending'}, uid: ''),
        ],
      );
      final registry = AccountWorkspaceRegistry();
      final rewards = _Rewards(accounts)..refreshGate = Completer<void>();
      addTearDown(accounts.dispose);
      addTearDown(registry.dispose);
      await tester.pumpWidget(
        DesktopTestApp(
          home: Scaffold(
            body: IndexedStack(
              index: 0,
              children: [
                WorkspaceActivityPage(registry: registry),
                for (final app in [
                  ManagedApp.qoderCn,
                  ManagedApp.zcode,
                  ManagedApp.loomy,
                  ManagedApp.traeCn,
                ])
                  AccountPresentationScope(
                    app: app,
                    registry: registry,
                    child: SingleChildScrollView(
                      child: PluginAccountsPanel(
                        accounts: accounts,
                        rewards: rewards,
                        providerIds: app.nativeProviders,
                        title: app.label,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      AccountTableEntry entry(String label) =>
          registry.entries.singleWhere((entry) => entry.label == label);
      expect(entry('observation').statusLabel, '活动查询未完成');
      expect(entry('submitted').statusLabel, '领取回执未确认');
      expect(entry('missing-device').attention, AccountAttention.actionRequired);
      for (final label in [
        'submitted',
        'observation',
        'discovery',
        'shared-device',
      ]) {
        expect(
          entry(label).attention,
          AccountAttention.awaitingVerification,
          reason: label,
        );
      }
      for (final label in [
        'ineligible',
        'no-evidence',
        'no-status-hook',
        'not-a-reward-provider',
      ]) {
        expect(entry(label).attention, AccountAttention.none, reason: label);
        expect(entry(label).resolution, isNull, reason: label);
      }
      expect(entry('not-a-reward-provider').hasRewards, isFalse);
      expect(entry('expired').resolution?.label, '重新授权');
      expect(entry('missing-uid').resolution, isNull);
      expect(
        entry('loomy-pending').attention,
        AccountAttention.awaitingVerification,
      );
      expect(entry('loomy-pending').resolution, isNull);
      expect(rewards.refreshes, 0);
      await tester.tap(find.text('待处理'));
      await tester.pumpAndSettle();
      expect(find.text('observation'), findsOneWidget);
      expect(find.text('discovery'), findsOneWidget);
      expect(find.text('ineligible'), findsNothing);
      expect(find.text('not-a-reward-provider'), findsNothing);
      for (final label in ['loomy-pending', 'expired', 'missing-uid']) {
        final item = find.text(label);
        await tester.ensureVisible(item);
        await tester.pumpAndSettle();
        await tester.tap(item);
        await tester.pumpAndSettle();
        expect(find.textContaining('同一活动不会重复提交'), findsOneWidget);
        expect(find.text('核验领取结果'), findsNothing, reason: label);
        expect(find.text('核对并领取'), findsNothing, reason: label);
        final more = find.text('更多操作');
        await tester.ensureVisible(more);
        await tester.pumpAndSettle();
        await tester.tap(more);
        await tester.pumpAndSettle();
        expect(find.text('移除账号'), findsOneWidget);
        for (final action in ['核验领取结果', '核对并领取', '核对并领取活动']) {
          expect(find.text(action), findsNothing, reason: label);
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('account-detail-sheet')), findsNothing);
      }
      expect(rewards.refreshes, 0);
      expect(rewards.claims, 0);
      await tester.ensureVisible(find.text('核验结果'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('核验结果'));
      await tester.pump();
      await tester.pump();
      expect(rewards.refreshedKey, 'qoder-cn#submitted');
      expect(entry('submitted').resolution, isNull);
      expect(rewards.refreshes, 1);
      expect(rewards.claims, 0);
      rewards.refreshGate!.complete();
      await tester.pumpAndSettle();
      expect(entry('submitted').resolution?.label, '核验结果');
      expect(rewards.refreshes, 1);
      expect(rewards.claims, 0);
    },
  );

  Future<_Rewards> mountAccount(
    WidgetTester tester,
    PluginAccount account,
  ) async {
    final accounts = _Accounts(_Runtime(), rows: [account]);
    final rewards = _Rewards(accounts);
    addTearDown(accounts.dispose);
    await tester.pumpWidget(
      DesktopTestApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PluginAccountsPanel(
              accounts: accounts,
              rewards: rewards,
              providerIds: {account.provider},
              title: 'Synthetic',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return rewards;
  }

  PluginAccount observed({
    Map<String, dynamic>? usage,
    Map<String, dynamic>? reward,
    String? error,
    DateTime? queriedAt,
  }) => PluginAccount(
    key: 'fixture#one',
    active: true,
    models: const [],
    usage: usage,
    error: error,
    queriedAt: queriedAt,
    facts: {
      'provider': 'fixture',
      'uid': 'synthetic',
      'realm': 'cn',
      'label': 'Synthetic account',
      'registrationId': 'one',
      if (reward != null) 'reward': reward,
    },
  );

  testDesktopWidgets(
    'account info identifies the official account and exact balance at 200 percent',
    (tester) async {
      tester.view.physicalSize = const Size(480, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final at = DateTime.utc(2026, 11, 12, 1, 20);
      await mountAccount(
        tester,
        observed(usage: {'balance': 860.25, 'unit': 'credits'}, queriedAt: at),
      );
      final open = find.byKey(const Key('account-fixture#one'));
      await tester.ensureVisible(open);
      await tester.tap(open);
      await tester.pumpAndSettle();
      final sheet = find.byKey(const Key('account-detail-sheet'));
      expect(MediaQuery.textScalerOf(tester.element(sheet)).scale(14), 28);
      double previous = 0;
      for (final (label, value) in [
        ('平台', 'Synthetic · cn'),
        ('账号 ID', 'synthetic'),
        ('授权状态', '已保存授权'),
        ('可用余额', '860.25 credits'),
        ('额度查询时间', creditTime(at)),
      ]) {
        final name = find.descendant(of: sheet, matching: find.text(label));
        final data = find.descendant(of: sheet, matching: find.text(value));
        expect(name, findsOneWidget);
        expect(data, findsOneWidget);
        final rect = tester.getRect(name);
        expect(rect.top, greaterThan(previous));
        expect(tester.getRect(data).left, greaterThanOrEqualTo(rect.right));
        await tester.ensureVisible(data);
        await tester.pumpAndSettle();
        expect(data.hitTestable(), findsOneWidget);
        previous = tester.getRect(name).top;
      }
      for (final label in ['官方套餐与额度', '更多操作']) {
        final item = find.descendant(of: sheet, matching: find.text(label));
        await tester.ensureVisible(item);
        await tester.pumpAndSettle();
        expect(item.hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testDesktopWidgets(
    'structured total credits show only the remaining balance',
    (tester) async {
      await mountAccount(
        tester,
        observed(
          usage: {
            'windows': [
              {
                'name': 'Credits',
                'amount': 0,
                'limit': 500,
                'unit': 'credits',
                'aside': true,
              },
              {
                'name': 'Extra credits',
                'amount': 0.04,
                'limit': 3400,
                'unit': 'credits',
                'aside': true,
              },
              {
                'name': 'Total credits',
                'amount': 0.04,
                'limit': 3900,
                'unit': 'credits',
              },
            ],
          },
        ),
      );
      expect(find.text('3899.96 credits'), findsOneWidget);
      expect(find.textContaining('已用'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('account-fixture#one')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Extra credits：已用 0.04 credits'),
        findsOneWidget,
      );
    },
  );

  testDesktopWidgets('native text-only summaries stay in details', (
    tester,
  ) async {
    await mountAccount(
      tester,
      observed(
        usage: {'balance': '12,224 credits', 'error': '', 'windows': []},
      ),
    );
    expect(find.text('12,224 credits'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('account-fixture#one')));
    await tester.pumpAndSettle();
    expect(find.text('官方额度摘要：12,224 credits'), findsOneWidget);
    expect(find.textContaining('尚无已核实余额'), findsNothing);
  });

  testDesktopWidgets(
    'display-only native windows retain their official summary',
    (tester) async {
      await mountAccount(
        tester,
        observed(
          usage: {
            'balance': '',
            'error': '',
            'windows': [
              {
                'name': 'Requests',
                'display': '42 / 100 requests',
                'amount': null,
                'limit': null,
                'used': null,
                'balance': null,
                'unit': '',
              },
            ],
          },
        ),
      );
      expect(find.text('Requests：42 / 100 requests'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('account-fixture#one')));
      await tester.pumpAndSettle();
      expect(find.text('Requests：42 / 100 requests'), findsOneWidget);
      expect(find.textContaining('数值未知'), findsNothing);
    },
  );

  testDesktopWidgets(
    'native informational windows show guidance instead of a zero share',
    (tester) async {
      await mountAccount(
        tester,
        observed(
          usage: {
            'balance': '',
            'error': '',
            'windows': [
              {
                'name': 'Start Plan',
                'display': 'Complete official verification',
                'amount': null,
                'limit': null,
                'used': 0,
                'balance': null,
                'aside': true,
                'unit': '',
              },
            ],
          },
        ),
      );
      await tester.tap(find.byKey(const ValueKey('account-fixture#one')));
      await tester.pumpAndSettle();
      expect(
        find.text('Start Plan：Complete official verification'),
        findsOneWidget,
      );
      expect(find.textContaining('使用率 0%'), findsNothing);
    },
  );

  testDesktopWidgets(
    'a failed quota query stays visible beside a confirmed reward',
    (tester) async {
      await mountAccount(
        tester,
        observed(
          usage: {'error': 'Usage query unavailable', 'signIn': 'kept'},
          error: 'usage_unavailable',
          reward: {
            'status': 'claimed',
            'credit': 100,
            'creditExpiresAt': '2026-12-20T06:30:00.125314Z',
            'unit': 'credits',
            'observedAt': DateTime.utc(
              2026,
              11,
              13,
              1,
              20,
            ).millisecondsSinceEpoch,
          },
        ),
      );
      expect(findTooltip('已确认领取，具体时间未知'), findsOneWidget);
      final row = tester
          .widget<CompactAccountsTable>(find.byType(CompactAccountsTable))
          .entries
          .single;
      expect(row.attention, AccountAttention.awaitingVerification);
      expect(row.resolution, isNull);
      expect(find.text('额度查询未完成'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('account-fixture#one')));
      await tester.pumpAndSettle();
      final localExpiry = DateTime.utc(
        2026,
        12,
        20,
        6,
        30,
      ).toLocal().toString().substring(0, 16);
      expect(find.textContaining('本次到账有效至 $localExpiry'), findsOneWidget);
      expect(find.textContaining('已确认领取。'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('account-detail-sheet')),
          matching: find.textContaining('核验于'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('account-detail-sheet')),
          matching: find.textContaining('时间未知'),
        ),
        findsNothing,
      );
      expect(find.textContaining('请核对授权、权益或网络'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('detail-fact-额度查询时间')),
          matching: find.text('未知'),
        ),
        findsOneWidget,
      );
    },
  );

  testDesktopWidgets(
    'retained quota is labelled with its last successful read time',
    (tester) async {
      await mountAccount(
        tester,
        observed(
          usage: {
            'balance': 12224,
            'unit': 'credits',
            'error': 'Usage query unavailable',
            'windows': [],
          },
          error: 'usage_unavailable',
          queriedAt: DateTime.utc(2026, 11, 12, 1, 20),
        ),
      );
      expect(find.text('12224 credits'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('account-fixture#one')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('detail-fact-额度查询时间')),
          matching: find.text(creditTime(DateTime.utc(2026, 11, 12, 1, 20))),
        ),
        findsOneWidget,
      );
    },
  );

  testDesktopWidgets(
    'an unresolved provider claim identifies the missing official receipt',
    (tester) async {
      await mountAccount(tester, observed(reward: {'status': 'pending'}));
      expect(find.text('领取回执未确认'), findsOneWidget);
    },
  );

  testDesktopWidgets(
    'a pending claim does not mask expired usage authorization',
    (tester) async {
      await mountAccount(
        tester,
        observed(
          usage: {'error': 'Usage query unavailable', 'signIn': 'expired'},
          error: 'authorization_required',
          reward: {'status': 'pending'},
        ),
      );
      await tester.tap(find.byKey(const ValueKey('account-fixture#one')));
      await tester.pumpAndSettle();
      final row = tester
          .widget<CompactAccountsTable>(find.byType(CompactAccountsTable))
          .entries
          .single;
      expect(row.attention, AccountAttention.actionRequired);
      expect(row.resolution!.label, '重新授权');
      expect(find.textContaining('未能确认本次领取的官方回执。'), findsOneWidget);
      expect(find.textContaining('额度授权已失效'), findsOneWidget);
      await tester.ensureVisible(find.text('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('更多操作'));
      await tester.pumpAndSettle();
      expect(find.text('核验领取结果'), findsNothing);
    },
  );

  for (final (activityNewer, hasGift) in [
    (true, false),
    (true, true),
    (false, false),
    (false, true),
  ]) {
    testDesktopWidgets(
      'ZCode expiry follows the latest gift observation (activity newer: $activityNewer, has gift: $hasGift) across the table and both detail tabs',
      (tester) async {
        final usageAt = DateTime.utc(2026, 11, 10, 8);
        final checkedAt = usageAt.add(Duration(hours: activityNewer ? 4 : -4));
        final oldExpiry = DateTime.utc(2099, 1, 3, 7);
        final newExpiry = DateTime.utc(2099, 1, 4, 4);
        await mountAccount(
          tester,
          PluginAccount(
            key: 'zcode#one',
            active: true,
            models: const [],
            queriedAt: usageAt,
            usage: {
              'plan': 'GLM Coding Lite',
              'windows': [
                {
                  'name': 'GLM gift',
                  'unit': 'tokens',
                  'runsOut': activityNewer ? 81.75 : (hasGift ? 13.25 : 0),
                  'runsOutAt': (activityNewer ? oldExpiry : newExpiry)
                      .toIso8601String(),
                  'resetsAt': (activityNewer ? oldExpiry : newExpiry)
                      .toIso8601String(),
                },
              ],
            },
            facts: {
              ...observed().facts,
              'provider': 'zcode',
              'reward': {
                'checkedAt': checkedAt.millisecondsSinceEpoch,
                'buckets': [
                  if (!activityNewer || hasGift)
                    {
                      'label': 'Start Plan gift',
                      'unit': 'tokens',
                      'remaining': activityNewer ? 13.25 : 81.75,
                      'expiresAt':
                          (activityNewer ? newExpiry : oldExpiry)
                              .millisecondsSinceEpoch ~/
                          1000,
                    },
                ],
              },
            },
          ),
        );
        final table = tester.widget<CompactAccountsTable>(
          find.byType(CompactAccountsTable),
        );
        final row = table.entries.single;
        expect(row.nextExpiry, hasGift ? newExpiry : null);
        expect(row.upcomingExpiryAmount, hasGift ? '13.25 tokens' : '—');
        expect(find.textContaining('81.75'), findsNothing);
        if (hasGift) expect(find.text('13.25 tokens'), findsOneWidget);
        await tester.tap(find.byKey(const Key('account-zcode#one')));
        await tester.pumpAndSettle();
        final sheet = find.byKey(const Key('account-detail-sheet'));
        Finder detail(Finder text) =>
            find.descendant(of: sheet, matching: text);
        for (final tab in ['账号信息', '额度到期']) {
          if (tab == '额度到期') {
            await tester.tap(find.text(tab));
            await tester.pumpAndSettle();
          } else {
            expect(
              detail(find.textContaining('GLM Coding Lite')),
              findsOneWidget,
            );
            expect(
              detail(find.textContaining('套餐与额度观测于 ${creditTime(usageAt)}')),
              findsOneWidget,
            );
            expect(
              detail(find.textContaining('活动额度观测于 ${creditTime(checkedAt)}')),
              findsOneWidget,
            );
          }
          expect(
            detail(find.textContaining('81.75 tokens')),
            !activityNewer && tab == '账号信息' ? findsOneWidget : findsNothing,
            reason: tab,
          );
          expect(
            detail(find.textContaining(creditTime(oldExpiry))),
            findsNothing,
            reason: tab,
          );
          final expiryObservation = activityNewer
              ? '活动余额 · ${creditTime(checkedAt)}'
              : '套餐与额度 · ${creditTime(usageAt)}';
          expect(
            detail(find.text('到期数据来源：$expiryObservation')),
            findsOneWidget,
          );
          expect(detail(find.textContaining('分别列示')), findsNothing);
          if (hasGift) {
            expect(detail(find.textContaining('13.25 tokens')), findsWidgets);
            expect(
              detail(find.textContaining(creditTime(newExpiry))),
              findsWidgets,
            );
          } else {
            expect(detail(find.text('平台未提供可核实的到期明细。')), findsOneWidget);
          }
        }
      },
    );
  }

  testDesktopWidgets(
    'fresh Start Plan quantities are independent of failed native usage',
    (tester) async {
      final base = observed();
      await mountAccount(
        tester,
        PluginAccount(
          key: 'zcode#one',
          active: true,
          models: const [],
          error: 'usage_unavailable',
          usage: {'error': 'Usage query unavailable'},
          facts: {
            ...base.facts,
            'provider': 'zcode',
            'reward': {
              'status': 'noOffer',
              'checkedAt': DateTime.now().millisecondsSinceEpoch,
              'buckets': [
                {
                  'label': 'Gift tokens',
                  'remaining': 12345678,
                  'unit': 'tokens',
                },
              ],
            },
          },
        ),
      );
      expect(find.text('本账号与设备未收到活动'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('account-zcode#one')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Gift tokens：剩余 12345678 tokens'),
        findsOneWidget,
      );
      expect(find.text('官方本次未向这个账号与绑定设备返回可领取活动。'), findsOneWidget);
      expect(find.text('套餐额度查询未完成。'), findsOneWidget);
      expect(find.textContaining('上次：Start Plan'), findsNothing);
    },
  );

  testDesktopWidgets(
    'ZCode shows the official reason for the current rejected plan',
    (tester) async {
      final base = observed();
      await mountAccount(
        tester,
        PluginAccount(
          key: 'zcode#one',
          active: true,
          models: const [],
          facts: {
            ...base.facts,
            'provider': 'zcode',
            'reward': {
              'status': 'rejected',
              'planId': 'night',
              'claims': {
                'night': {'state': 'rejected', 'message': '本次活动未开放。'},
                'old': {'state': 'rejected', 'message': '历史活动原因。'},
              },
            },
          },
        ),
      );
      await tester.tap(find.byKey(const ValueKey('account-zcode#one')));
      await tester.pumpAndSettle();
      expect(find.textContaining('本次活动未开放。'), findsOneWidget);
      expect(find.textContaining('历史活动原因。'), findsNothing);
    },
  );

  testDesktopWidgets(
    'a newly offered ZCode activity uses the claim owner with an older unresolved plan',
    (tester) async {
      final rewards = await mountAccount(
        tester,
        PluginAccount(
          key: 'zcode#one',
          active: true,
          models: const [],
          error: 'usage_unavailable',
          facts: {
            ...observed().facts,
            'provider': 'zcode',
            'reward': {
              'status': 'claimable',
              'planId': 'weekend',
              'claims': {
                'night': {'state': 'unknown'},
              },
            },
          },
        ),
      );
      expect(find.text('已收到活动'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('account-zcode#one')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('核对并领取活动'));
      await tester.tap(find.text('核对并领取活动'));
      await tester.pumpAndSettle();
      expect(rewards.claims, 1);
      expect(rewards.refreshes, 0);
    },
  );

  testDesktopWidgets(
    'an old unscoped ZCode status is not the current receipt',
    (tester) async {
      await mountAccount(
        tester,
        PluginAccount(
          key: 'zcode#one',
          active: true,
          models: const [],
          facts: {
            ...observed().facts,
            'provider': 'zcode',
            'reward': {
              'status': 'pending',
              'claims': {
                'old': {'state': 'unknown', 'previous': []},
              },
            },
          },
        ),
      );
      expect(find.text('活动信息暂不完整'), findsOneWidget);
      expect(find.text('领取回执未确认'), findsNothing);
    },
  );

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
    testDesktopWidgets(
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
          DesktopTestApp(
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

  testDesktopWidgets(
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
        DesktopTestApp(
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
      expect(find.byKey(const Key('plugin-auth-provider')), findsNothing);
      expect(find.byKey(const Key('plugin-auth-method')), findsNothing);
      final primary = tester.widget<FButton>(
        find
            .ancestor(of: find.text('开始授权'), matching: find.byType(FButton))
            .first,
      );
      expect(primary.variant, FButtonVariant.primary);
      await tester.tap(find.text('邀请注册'));
      await tester.pumpAndSettle();
      expect(runtime.calls, isEmpty);
      expect(find.textContaining('未能打开浏览器'), findsOneWidget);
      await tester.tap(find.text('开始授权'));
      await tester.pump();
      await tester.pump();
      expect(runtime.calls.any((c) => c.$1 == 'authorize'), isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testDesktopWidgets('API-key entry bypasses invitation registration', (
    tester,
  ) async {
    final runtime = _Runtime()..auto = true;
    final accounts = _Accounts(runtime);
    addTearDown(accounts.dispose);
    await tester.pumpWidget(
      DesktopTestApp(
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
    await tester.tap(
      find.text('继续').evaluate().isEmpty ? find.text('开始授权') : find.text('继续'),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('plugin-auth-input')), findsOneWidget);
    expect(runtime.calls.any((c) => c.$1 == 'authorize'), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testDesktopWidgets(
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
        DesktopTestApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FButton(
                mainAxisSize: MainAxisSize.min,
                size: FButtonSizeVariant.sm,
                onPress: () => showDialog<String>(
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
      await tester.tap(
        find.text('继续').evaluate().isEmpty
            ? find.text('开始授权')
            : find.text('继续'),
      );
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

  testDesktopWidgets(
    'ZCode details keep amounts exact and only verify a current unresolved claim',
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
                'planId': 'night',
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
        DesktopTestApp(
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
      expect(find.text('12345678 tokens / 0.875 credits'), findsNothing);
      expect(find.text('领取回执未确认'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('expiry-time-zcode#one')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('account-zcode#one')));
      await tester.pumpAndSettle();
      expect(find.textContaining('verified-user'), findsWidgets);
      expect(find.textContaining('未能确认本次领取的官方回执。同一活动不会重复提交。'), findsOneWidget);
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
      expect(rewards.refreshedUsage, isFalse);
      rewards.failRefresh = true;
      await tester.ensureVisible(find.text('刷新额度'));
      await tester.tap(find.text('刷新额度'));
      await tester.pumpAndSettle();
      expect(rewards.refreshedUsage, isTrue);
      expect(
        find.descendant(
          of: find.byKey(const Key('account-detail-sheet')),
          matching: find.textContaining('操作未完成'),
        ),
        findsOneWidget,
      );
      expect(find.byType(FSwitch), findsNothing);
      await tester.pumpWidget(const SizedBox());
      accounts.dispose();
    },
  );

  testDesktopWidgets(
    'native prompts preserve method index and show browser failures before manual completion',
    (tester) async {
      final runtime = _Runtime();
      final nativeAccounts = _Accounts(runtime);
      final completed = Completer<String?>();
      await tester.pumpWidget(
        DesktopTestApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FButton(
                mainAxisSize: MainAxisSize.min,
                size: FButtonSizeVariant.sm,
                onPress: () async => completed.complete(
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
      await tester.tap(
        find.text('继续').evaluate().isEmpty
            ? find.text('开始授权')
            : find.text('继续'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('plugin-auth-prompt-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('海外').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('继续').evaluate().isEmpty
            ? find.text('开始授权')
            : find.text('继续'),
      );
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('plugin-auth-input'));
      expect(tester.widget<FTextField>(input).obscureText, true);
      await tester.enterText(input, 'synthetic-secret');
      await tester.tap(
        find.text('继续').evaluate().isEmpty
            ? find.text('开始授权')
            : find.text('继续'),
      );
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

  testDesktopWidgets(
    'disposing an automatic sign-in cancels its owned callback',
    (tester) async {
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
        DesktopTestApp(
          home: PluginSignInDialog(
            accounts: accounts,
            providerIds: const {'fixture'},
            title: '添加账号',
          ),
        ),
      );
      await tester.tap(
        find.text('继续').evaluate().isEmpty
            ? find.text('开始授权')
            : find.text('继续'),
      );
      await tester.pump();
      await tester.pump();
      expect(runtime.callback, isNotNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(runtime.cancelled, true);
      expect(accounts.saved, null);
      accounts.dispose();
    },
  );

  testDesktopWidgets(
    'cancel stops the callback before the dialog closing animation',
    (tester) async {
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
        DesktopTestApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FButton(
                mainAxisSize: MainAxisSize.min,
                size: FButtonSizeVariant.sm,
                onPress: () async => completed.complete(
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
        await tester.tap(
          find.text('继续').evaluate().isEmpty
              ? find.text('开始授权')
              : find.text('继续'),
        );
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
    },
  );

  testDesktopWidgets(
    'API authorization masks the key and preserves the native method',
    (tester) async {
      final runtime = _Runtime()..auto = true;
      final accounts = _Accounts(runtime);
      final completed = Completer<String?>();
      await tester.pumpWidget(
        DesktopTestApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FButton(
                mainAxisSize: MainAxisSize.min,
                size: FButtonSizeVariant.sm,
                onPress: () async => completed.complete(
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
      await tester.tap(
        find.text('继续').evaluate().isEmpty
            ? find.text('开始授权')
            : find.text('继续'),
      );
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('plugin-auth-input'));
      expect(tester.widget<FTextField>(input).obscureText, true);
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

  testDesktopWidgets(
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
      var activations = 0;
      await tester.pumpWidget(
        DesktopTestApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PluginAccountsPanel(
                accounts: accounts,
                rewards: rewards,
                providerIds: const {'workbuddy'},
                title: 'WorkBuddy',
                activate: (key) async {
                  activated = key;
                  activations++;
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
      expect(activated, isNull);
      expect(find.textContaining('关闭 WorkBuddy'), findsOneWidget);
      expect(find.textContaining('自动打开'), findsOneWidget);
      await tester.tap(find.byKey(const Key('plugin-activate-cancel')));
      await tester.pumpAndSettle();
      expect(activated, isNull);
      await tester.tap(find.text('切换客户端账号'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('plugin-activate-confirm')));
      await tester.pumpAndSettle();
      expect(activated, 'workbuddy#one');
      expect(activations, 1);
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
          of: find.byKey(const Key('account-detail-sheet')),
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

  for (final exit in ['cancel', 'replace owner', 'dispose']) {
    testDesktopWidgets(
      'row switch requires closure confirmation before $exit at large text',
      (tester) async {
        tester.view.physicalSize = const Size(480, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final account = PluginAccount(
          key: 'workbuddy#row',
          active: true,
          models: const [],
          facts: {
            'provider': 'workbuddy',
            'uid': 'official-user',
            'realm': 'www.workbuddy.cn',
            'label': 'long-account-for-confirmation@example.test',
            'registrationId': 'row',
          },
        );
        final accounts = _Accounts(_Runtime(), rows: [account]);
        addTearDown(accounts.dispose);
        var activations = 0;
        Widget panel(_Accounts owner) => DesktopTestApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: PluginAccountsPanel(
                accounts: owner,
                rewards: _Rewards(owner),
                providerIds: const {'workbuddy'},
                title: 'WorkBuddy',
                activate: (_) async {
                  activations++;
                  return 'opened';
                },
              ),
            ),
          ),
        );
        await tester.pumpWidget(panel(accounts));
        await tester.pumpAndSettle();
        final switchButton = find.byKey(const Key('activate-workbuddy#row'));
        await tester.ensureVisible(switchButton);
        await tester.pumpAndSettle();
        await tester.tap(switchButton);
        await tester.pumpAndSettle();
        expect(activations, 0);
        expect(find.textContaining('关闭 WorkBuddy'), findsOneWidget);
        final confirm = find.byKey(const Key('plugin-activate-confirm'));
        expect(confirm.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (exit == 'cancel') {
          await tester.tap(find.byKey(const Key('plugin-activate-cancel')));
        } else if (exit == 'replace owner') {
          final next = _Accounts(_Runtime(), rows: [account]);
          addTearDown(next.dispose);
          await tester.pumpWidget(panel(next));
          await tester.pumpAndSettle();
          await tester.tap(confirm);
        } else {
          await tester.pumpWidget(const SizedBox.shrink());
        }
        await tester.pumpAndSettle();
        expect(activations, 0);
        expect(find.byKey(const Key('plugin-activate-confirm')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
