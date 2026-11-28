import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/credit_expiry_history.dart';
import '../lib/magpie_connection.dart';
import '../lib/magpie_usage.dart';
import '../lib/workspace_usage.dart';
import 'desktop_test_app.dart';
import 'model_workspace_fixture.dart';

Map<String, dynamic> ledger(DateTime date, {int calls = 3}) {
  final tag = date.toIso8601String().split('T').first;
  Map<String, int> totals(int n) => {
    'calls': n,
    'errors': n == 0 ? 0 : 1,
    'input': n * 120,
    'output': n * 15,
  };
  final at = date.add(const Duration(hours: 8));
  return {
    'period': '$tag..$tag',
    'provider': 'loongpass',
    'bucket': 'hour',
    ...totals(calls),
    'series': [
      for (
        var t = date;
        t.isBefore(DateTime(date.year, date.month, date.day + 1));
        t = t.add(const Duration(hours: 1))
      )
        {'time': t.toUtc().toIso8601String(), ...totals(t == at ? calls : 0)},
    ],
    'rows': [
      if (calls > 0)
        for (final handedOn in [false, true])
          {
            't': at.toUtc().toIso8601String(),
            'provider': 'loongpass',
            'handed_on': handedOn,
            'model': 'requested',
            'served': handedOn ? 'intermediate' : 'example-model',
            'credits': handedOn ? 8 : 0.03125,
            'providerAccount': '示例账号',
          },
    ],
  };
}

class FixtureUsage extends MagpieUsage {
  FixtureUsage() : super(clock: () => DateTime(2026, 11, 25, 12));
  @override
  UsageDay? day(DateTime date) => UsageDay.fromLedger(
    date,
    now,
    ledger(date, calls: date == today ? 3 : 0),
  );
}

class _LoopbackHttp extends HttpOverrides {}

void main() {
  test('seven independent local ledger days retain a known zero and last good data on failure', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requested = <Map<String, String>>[];
    var offline = false;
    server.listen((req) async {
      final q = req.uri.queryParameters;
      requested.add(q);
      expect(req.uri.path, '/v1/magpie/usage/requests');
      if (offline) {
        req.response.statusCode = 503;
      } else {
        final date = DateTime.parse(q['period']!.split('..').first);
        req.response.write(
          jsonEncode(ledger(date, calls: date.day == 25 ? 3 : 0)),
        );
      }
      await req.response.close();
    });
    final usage = HttpOverrides.runWithHttpOverrides(
      () => MagpieUsage(
        clock: () => DateTime(2026, 11, 25, 12),
        locate: () async => Uri.http('127.0.0.1:${server.port}'),
      ),
      _LoopbackHttp(),
    );
    addTearDown(usage.dispose);
    usage.start();
    await usage.refresh();
    expect(requested.map((r) => r['period']).toSet(), hasLength(7));
    expect(
      requested.every(
        (r) =>
            r['via'] == 'through' &&
            r['provider'] == 'loongpass' &&
            r['computer'] == 'this',
      ),
      isTrue,
    );
    final today = usage.day(usage.today)!;
    expect(today.totals.calls, 3);
    expect(today.recent.single.credits, 0.03125);
    expect(today.hours[8].totals.input, 360);
    expect(today.hours[8].totals.output, 45);
    expect(today.recent.map((c) => (c.model, c.account)), [
      ('example-model', '示例账号'),
    ]);
    expect(usage.day(usage.dates.first)!.totals.calls, 0);
    offline = true;
    await usage.refresh();
    expect(requested, hasLength(8));
    expect(usage.unavailable(usage.today), isTrue);
    expect(usage.day(usage.today), same(today));
  });

  test(
    'mismatched ledger scopes and incomplete timelines cannot supply a zero',
    () {
      final d = DateTime(2026, 11, 25);
      for (final row in [
        ledger(d)..['provider'] = 'other',
        ledger(d)..['calls'] = 5,
        ledger(d)..['series'] = [],
      ]) {
        expect(() => UsageDay.fromLedger(d, d, row), throwsFormatException);
      }
    },
  );

  test('gateway discovery accepts the native custom loopback port', () async {
    for (final host in [
      'http://127.0.0.1:35887',
      'http://[::1]:45678',
      'https://example.test',
      'http://user@localhost:3425',
    ]) {
      final gateway = MagpieConnection(
        run: (args, {input}) async {
          expect(args, ['status', '--json']);
          return jsonEncode({'running': true, 'url': host});
        },
      ).localGateway();
      if (host.contains('127.0.0.1') || host.contains('[::1]')) {
        expect((await gateway).toString(), host);
      } else {
        await expectLater(gateway, throwsFormatException);
      }
    }
  });

  testDesktopWidgets(
    'overview opens the chosen metric, drills into hours and returns',
    (tester) async {
      final usage = FixtureUsage(), accounts = WorkspaceFixtureAccounts();
      addTearDown(usage.dispose);
      addTearDown(accounts.dispose);
      accounts.expiryHistory.addAll([
        (
          provider: 'zcode',
          account: '示例甲',
          batch: CreditExpiryEvidence(
            DateTime(2026, 11, 24, 15, 45),
            'tokens',
            unused: 12345678,
          ),
        ),
        (
          provider: 'workbuddy',
          account: '示例乙',
          batch: CreditExpiryEvidence(
            DateTime(2026, 11, 24),
            'credits',
            dateOnly: true,
          ),
        ),
        (
          provider: 'qoder',
          account: '示例丙',
          batch: CreditExpiryEvidence(
            DateTime(2026, 11, 23, 8),
            'credits',
            unused: 12.5,
          ),
        ),
      ]);
      await tester.pumpWidget(
        DesktopTestApp(
          home: Align(
            alignment: Alignment.topCenter,
            child: WorkspaceUsageSummary(usage: usage, accounts: accounts),
          ),
        ),
      );
      await tester.tap(find.text('今日调用'));
      await tester.pumpAndSettle();
      final openCalls = find.text('本机调用明细');
      expect(find.text('用量与到期'), findsOneWidget);
      expect(find.text('本机调用 · 全部来源（次）'), findsOneWidget);
      expect(find.text('到期 · 全部来源（批）'), findsOneWidget);
      await tester.scrollUntilVisible(
        openCalls,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(openCalls);
      await tester.pumpAndSettle();
      expect(find.text('其中 1 次最终失败'), findsOneWidget);
      expect(find.textContaining('本次实扣 0.03125 积分'), findsOneWidget);
      expect(find.text('已记录输入 360 tokens · 输出 45 tokens'), findsOneWidget);
      final back = find.text('返回我的应用');
      await tester.scrollUntilVisible(
        back,
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(find.text('2 批已确认 · 1 批待核实'), findsOneWidget);
      await tester.tap(find.text('近 7 天到期未用'));
      await tester.pumpAndSettle();
      expect(find.text('哪些来源到期未用'), findsOneWidget);
      expect(find.textContaining('12,345,678 tokens'), findsWidgets);
      final prev = find.bySemanticsLabel('上一时段');
      await tester.ensureVisible(prev);
      await tester.tap(prev.first);
      await tester.pumpAndSettle();
      expect(find.text('11 月 24 日 全天'), findsOneWidget);
      final hour = find.text('按小时');
      await tester.scrollUntilVisible(
        hour,
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(hour);
      await tester.pumpAndSettle();
      expect(find.text('当天仅知日期 · 1 批'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
