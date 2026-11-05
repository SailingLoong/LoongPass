import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/qoder_accounts_panel.dart';
import '../lib/qoder_account_flow.dart';
import '../lib/qoder_journal.dart';
import '../lib/qoder_pat_import.dart';
import '../lib/mac_qoder_import.dart';
import 'qoder_claim_test.dart' as f;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late File source;
  late QoderPatCandidate candidate;
  late QoderAttemptJournal journal;
  setUp(() async {
    temp = Directory(
      await (await Directory.systemTemp.createTemp(
        'loongpass-panel-',
      )).resolveSymbolicLinks(),
    );
    await Process.run('chmod', ['700', temp.path]);
    source = File('${temp.path}/chosen.json');
    await source.writeAsString(
      jsonEncode({
        'id': f.identity.providerId,
        'settingsConfig': {'apiKey': 'SYNTHETIC_PAT'},
        'meta': {'providerType': 'qoder_sdk'},
      }),
    );
    candidate = await QoderPatImport.read(
      source,
      providerId: f.identity.providerId,
    );
    journal = QoderAttemptJournal(temp, syncDirectory: () async {});
  });
  tearDown(() async => temp.delete(recursive: true));
  Future<void> mount(
    WidgetTester tester,
    QoderAccountFlow flow,
    QoderFilePicker picker, {
    double width = 800,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: QoderAccountsPanel(flow: flow, picker: picker),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'imported candidate is visible without secrets and real check-in remains unavailable',
    (tester) async {
      final flow = QoderAccountFlow(openJournal: () async => journal);
      addTearDown(flow.dispose);
      await mount(tester, flow, (_) async => candidate);
      await tester.tap(find.byKey(const Key('qoder-import-file')));
      await tester.pumpAndSettle();
      expect(find.text(f.identity.providerId), findsOneWidget);
      expect(find.text('已导入，未验证'), findsOneWidget);
      expect(find.textContaining('SYNTHETIC_PAT'), findsNothing);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(Key('qoder-claim-${f.identity.providerId}')),
            )
            .onPressed,
        isNull,
      );
      expect(find.textContaining('官方设备验证尚未接入'), findsOneWidget);
    },
  );
  testWidgets('cancellation and repeated import do not create duplicate rows', (
    tester,
  ) async {
    final flow = QoderAccountFlow(openJournal: () async => journal);
    addTearDown(flow.dispose);
    var cancel = true;
    await mount(tester, flow, (_) async => cancel ? null : candidate);
    await tester.tap(find.byKey(const Key('qoder-import-file')));
    await tester.pumpAndSettle();
    expect(flow.accounts, isEmpty);
    expect(find.text('已取消，未导入账号。'), findsOneWidget);
    cancel = false;
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(const Key('qoder-import-file')));
      await tester.pumpAndSettle();
    }
    expect(flow.accounts.length, 1);
    expect(find.text(f.identity.providerId), findsOneWidget);
  });
  testWidgets(
    'pending picker blocks duplicate clicks and errors never expose secret text',
    (tester) async {
      final flow = QoderAccountFlow(openJournal: () async => journal);
      addTearDown(flow.dispose);
      final gate = Completer<QoderPatCandidate?>();
      var picks = 0;
      await mount(tester, flow, (_) async {
        picks++;
        return gate.future;
      });
      await tester.tap(find.byKey(const Key('qoder-import-file')));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('qoder-import-file')))
            .onPressed,
        isNull,
      );
      gate.completeError(StateError('SYNTHETIC_SECRET'));
      await tester.pumpAndSettle();
      expect(picks, 1);
      expect(flow.accounts, isEmpty);
      expect(find.textContaining('SYNTHETIC_SECRET'), findsNothing);
      expect(find.text('导入未完成，请检查所选配置文件。'), findsOneWidget);
    },
  );
  testWidgets(
    'multiple-provider picker returns the chosen ID and can be cancelled',
    (tester) async {
      final flow = QoderAccountFlow(openJournal: () async => journal);
      addTearDown(flow.dispose);
      String? selected;
      await mount(tester, flow, (choose) async {
        selected = await choose(['first', f.identity.providerId]);
        return selected == null ? null : candidate;
      });
      await tester.tap(find.byKey(const Key('qoder-import-file')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(Key('qoder-provider-${f.identity.providerId}')),
      );
      await tester.pumpAndSettle();
      expect(selected, f.identity.providerId);
      expect(flow.accounts.length, 1);
    },
  );
  testWidgets(
    'complete selected-file to protocol UI path never labels an unknown attempt successful',
    (tester) async {
      const channel = MethodChannel('com.sailingloong.loongpass/files');
      final methods = <String>[];
      final nativeCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        nativeCalls.add(call.method);
        return call.method == 'chooseQoderImportSource' ? source.path : null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final flow = QoderAccountFlow(
        openJournal: () async => journal,
        authenticate: (_) async => QoderSession(f.listing(), (r) async {
          methods.add(r.method);
          if (r.method == 'POST') throw StateError('lost');
          return f.reply(r);
        }),
      );
      addTearDown(flow.dispose);
      await mount(tester, flow, const MacQoderImport().select, width: 480);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('qoder-import-file')));
        for (var i = 0; i < 200 && flow.accounts.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      await tester.pumpAndSettle();
      expect(flow.accounts.length, 1);
      expect(nativeCalls, ['chooseQoderImportSource', 'releaseSelectedSource']);
      for (var n = 0; n < 2; n++) {
        await tester.runAsync(() async {
          await tester.tap(
            find.byKey(Key('qoder-claim-${f.identity.providerId}')),
          );
          for (var i = 0; i < 200 && flow.busy; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        });
        await tester.pumpAndSettle();
        if (n == 0) {
          expect(find.text('结果未知，不重复领取'), findsOneWidget);
          expect(find.textContaining('+100'), findsNothing);
        }
      }
      expect(methods, ['POST', 'GET']);
      expect(find.text('已确认领取，新增额度未知'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('a slow importer completing after page closes is not added', (
    tester,
  ) async {
    final flow = QoderAccountFlow(openJournal: () async => journal);
    addTearDown(flow.dispose);
    final gate = Completer<QoderPatCandidate?>();
    await mount(tester, flow, (_) async => gate.future);
    await tester.tap(find.byKey(const Key('qoder-import-file')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    gate.complete(candidate);
    await tester.pumpAndSettle();
    expect(flow.accounts, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'replacing the flow during a file choice ignores the stale candidate',
    (tester) async {
      final first = QoderAccountFlow(openJournal: () async => journal);
      final second = QoderAccountFlow(openJournal: () async => journal);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final gate = Completer<QoderPatCandidate?>();
      await mount(tester, first, (_) async => gate.future);
      await tester.tap(find.byKey(const Key('qoder-import-file')));
      await tester.pump();
      await mount(tester, second, (_) async => candidate);
      gate.complete(candidate);
      await tester.pumpAndSettle();
      expect(first.accounts, isEmpty);
      expect(second.accounts, isEmpty);
      await tester.tap(find.byKey(const Key('qoder-import-file')));
      await tester.pumpAndSettle();
      expect(second.accounts.length, 1);
      expect(first.accounts, isEmpty);
    },
  );
  for (final replayed in [false, true]) {
    testWidgets(
      'verified receipt displays the exact credit outcome replayed=$replayed',
      (tester) async {
        final flow = QoderAccountFlow(
          openJournal: () async => journal,
          authenticate: (_) async => QoderSession(
            f.listing(),
            (r) async =>
                f.reply(r, body: {...f.receipt(), 'replayed': replayed}),
          ),
        );
        addTearDown(flow.dispose);
        await mount(tester, flow, (_) async => candidate);
        await tester.tap(find.byKey(const Key('qoder-import-file')));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(
            find.byKey(Key('qoder-claim-${f.identity.providerId}')),
          );
          for (var i = 0; i < 200 && flow.busy; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        });
        await tester.pumpAndSettle();
        expect(
          find.text(replayed ? '本轮已领取，未新增额度' : '本次领取成功 +100'),
          findsOneWidget,
        );
        if (replayed) expect(find.textContaining('+100'), findsNothing);
      },
    );
  }
}
