import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/model_service.dart';
import '../lib/workspace_tools.dart';
import 'memory_account_store.dart';
import 'model_test_support.dart';

void main() {
  testWidgets(
    'multiple account connections expose catalogs and copy distinct grants',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final provider = PoolProvider('synthetic', ModelProtocol.messages);
      late ModelService service;
      late ModelBinding a, b;
      await tester.runAsync(() async {
        service = ModelService(store: MemoryAccountStore('page'), port: 0)
          ..register(provider);
        await service.load();
        a = await service.addAccount(providerId: provider.id, accountId: 'a');
        b = await service.addAccount(providerId: provider.id, accountId: 'b');
      });
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
        expect(find.text('only-a'), findsOneWidget);
        expect(find.text('only-b'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        final before = provider.discoveries;
        await tester.runAsync(() async {
          await tester.tap(find.text('启动本地服务'));
          while (service.busy) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        });
        await tester.pumpAndSettle();
        expect(service.running, isTrue);
        final copy = find.byKey(ValueKey('copy-${a.id}'));
        await tester.ensureVisible(copy);
        await tester.tap(copy);
        await tester.pumpAndSettle();
        expect(Uri.parse(copied!).queryParameters['key'], a.key);
        expect(Uri.parse(copied!).queryParameters['models'], 'shared,only-a');
        expect(a.key, isNot(b.key));
        expect(
          provider.discoveries,
          before,
          reason: 'render/start/copy must not trigger discovery',
        );
        await tester.ensureVisible(find.text('停止本地服务'));
        await tester.runAsync(() async {
          await tester.tap(find.text('停止本地服务'));
          while (service.busy) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        });
        await tester.pumpAndSettle();
        expect(service.running, isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
        await tester.runAsync(service.dispose);
        await tester.runAsync(() async {
          await provider.events.close();
        });
      }
    },
  );
}
