import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loongpass/zcode_accounts_panel.dart';
import 'package:loongpass/zcode_native.dart';
import 'package:loongpass/zcode_promotions.dart';
import 'package:loongpass/zcode_workspace.dart';

void main() {
  testWidgets('mount has no native calls and labels ZCode as activities', (tester) async {
    final calls = <String>[];
    Future<Object?> call(String method, Map<String, Object?> args) async {
      calls.add(method);
      return {'available': true, 'reason': null};
    }
    final owner = ZcodeWorkspace(native: ZcodeNativeClient(call: call),
      promotions: ZcodePromotionsClient(call: call));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: ZcodeAccountsPanel(workspace: owner)))));
    expect(calls, isEmpty);
    expect(find.text('半夜与周末活动'), findsOneWidget);
    expect(find.textContaining('签到'), findsNothing);
    for (final key in ['zcode-status', 'zcode-stop', 'zcode-capture-current',
      'zcode-capture-selected', 'zcode-switch', 'zcode-restore-selected',
      'zcode-reopen', 'zcode-preview', 'zcode-claim']) {
      expect(tester.widget<ButtonStyleButton>(find.byKey(Key(key))).onPressed, isNull);
    }
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('zcode-automatic')))
      .onChanged, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(owner.disposed, isTrue);
    expect(calls, isEmpty);
  });

  testWidgets('explicit status then capture unlocks activity preview', (tester) async {
    final calls = <String>[];
    var captured = false;
    Future<Object?> call(String method, Map<String, Object?> args) async {
      calls.add(method);
      if (method == 'status') return {'available': captured,
        'reason': captured ? null : 'NativeCaptureRequired'};
      if (method == 'promotionStatus') return {'available': true, 'reason': null};
      if (method == 'captureCurrent') {
        captured = true;
        return {'accountId': 'a' * 64, 'revision': 'b' * 64,
          'family': 'zai', 'label': 'Synthetic'};
      }
      return {'status': 'claimable', 'canClaim': true, 'planId': 'synthetic',
        'planName': '半夜活动', 'windowPolicy': 'serverPreview', 'exactOfferWindow': null};
    }
    final owner = ZcodeWorkspace(native: ZcodeNativeClient(call: call),
      promotions: ZcodePromotionsClient(call: call), nativeValidated: true);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: ZcodeAccountsPanel(workspace: owner)))));
    expect(calls, isEmpty);
    await tester.tap(find.byKey(const Key('zcode-status')));
    await tester.pump();
    expect(calls, ['status', 'promotionStatus']);
    await tester.tap(find.byKey(const Key('zcode-capture-current')));
    await tester.pump();
    expect(owner.selected?.label, 'Synthetic');
    await tester.ensureVisible(find.byKey(const Key('zcode-preview')));
    await tester.tap(find.byKey(const Key('zcode-preview')));
    await tester.pump();
    expect(owner.canClaim, isTrue);
    expect(calls.where((call) => call == 'claimPromotions'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('automatic timer is session-only and first polls at ten minutes', (tester) async {
    final calls = <String>[];
    Future<Object?> call(String method, Map<String, Object?> args) async {
      calls.add(method);
      if (method == 'status' || method == 'promotionStatus') {
        return {'available': true, 'reason': null};
      }
      if (method == 'captureCurrent') return {'accountId': 'a' * 64,
        'revision': 'b' * 64, 'family': 'zai', 'label': 'Synthetic'};
      return {'status': method == 'claimPromotions' ? 'claimed' : 'claimable',
        'canClaim': method != 'claimPromotions', 'planId': 'synthetic',
        'windowPolicy': 'serverPreview', 'exactOfferWindow': null};
    }
    final owner = ZcodeWorkspace(native: ZcodeNativeClient(call: call),
      promotions: ZcodePromotionsClient(call: call), nativeValidated: true);
    await owner.refreshStatus(); await owner.captureCurrent();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: ZcodeAccountsPanel(workspace: owner)))));
    final before = calls.length;
    owner.setAutomatic(true);
    await tester.pump(const Duration(minutes: 9, seconds: 59));
    expect(calls.length, before);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(calls.sublist(before), ['previewPromotions', 'claimPromotions']);
    await tester.pumpWidget(const SizedBox.shrink());
    final stopped = calls.length;
    await tester.pump(const Duration(minutes: 20));
    expect(calls.length, stopped);
  });
}
