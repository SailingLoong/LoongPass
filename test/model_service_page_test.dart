import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/model_service.dart';
import '../lib/workspace_tools.dart';
import 'memory_account_store.dart';
import 'model_service_checks.dart' show SyntheticProvider;

void main() {
  testWidgets(
    'saved selection starts, exports and stops the real local provider',
    (tester) async {
      final service = ModelService(
        store: MemoryAccountStore('page-synthetic'),
        port: 0,
      )..register(SyntheticProvider());
      await service.load();
      await service.configure(
        providerId: 'synthetic',
        accountId: 'account-a',
        model: 'synthetic-model',
      );
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData')
            copied = (call.arguments as Map)['text'];
          return null;
        },
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: ModelServicesPage(service: service)),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Synthetic account'), findsOneWidget);
        expect(
          find.widgetWithText(TextField, 'synthetic-model'),
          findsOneWidget,
        );

        Future<void> tapAndWait(String label, bool running) async {
          await tester.runAsync(() async {
            await tester.tap(find.text(label));
            final limit = DateTime.now().add(const Duration(seconds: 5));
            while (service.busy || service.running != running) {
              if (DateTime.now().isAfter(limit))
                throw StateError('service command did not finish');
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
          });
          await tester.pumpAndSettle();
        }

        await tapAndWait('保存并启动', true);
        expect(find.text('本地服务运行中'), findsOneWidget);
        await tester.tap(find.text('复制 Magpie 接入链接'));
        await tester.pumpAndSettle();
        final link = Uri.parse(copied!);
        expect(link.queryParameters['models'], 'synthetic-model');
        expect(link.queryParameters['anthropic'], service.endpoint.toString());
        expect(link.queryParameters['key'], service.callerKey);
        await tapAndWait('停止本地服务', false);
        expect(find.text('尚未启动'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
        await service.dispose();
      }
    },
  );
}
