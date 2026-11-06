import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/app_updates.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.sailingloong.loongpass/updates');
  late Map<String, Object?> native;
  late List<String> calls;
  var failSave = false;
  setUp(() {
    native = {
      'version': '1.0.0 (29)',
      'canCheck': true,
      'automaticChecks': true,
      'automaticDownloads': false,
    };
    calls = [];
    failSave = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'setAutomaticChecks' ||
              call.method == 'setAutomaticDownloads') {
            if (failSave) throw PlatformException(code: 'unavailable');
            native[call.method == 'setAutomaticChecks'
                    ? 'automaticChecks'
                    : 'automaticDownloads'] =
                call.arguments;
          }
          return native;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  testWidgets(
    'settings read native state; only explicit check starts an update',
    (tester) async {
      final updates = AppUpdates();
      addTearDown(updates.dispose);
      await updates.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AppUpdateCard(updates: updates)),
        ),
      );
      await tester.pump();
      expect(find.text('当前版本 1.0.0 (29)'), findsOneWidget);
      expect(calls, ['state']);
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      expect(calls, ['state', 'check']);
    },
  );
  test(
    'native preference remains authoritative across save failure and restoration',
    () async {
      final updates = AppUpdates();
      await updates.load();
      await updates.setAutomaticDownloads(true);
      expect(updates.automaticDownloads, isTrue);
      failSave = true;
      await updates.setAutomaticChecks(false);
      expect(updates.automaticChecks, isTrue);
      expect(updates.error, isNotNull);
      updates.dispose();
      final restored = AppUpdates();
      await restored.load();
      expect(restored.automaticDownloads, isTrue);
      expect(restored.automaticChecks, isTrue);
      restored.dispose();
    },
  );
  testWidgets('busy native updater prevents duplicate checks', (tester) async {
    native['canCheck'] = false;
    final updates = AppUpdates();
    addTearDown(updates.dispose);
    await updates.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AppUpdateCard(updates: updates)),
      ),
    );
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
    expect(calls, ['state']);
  });
}
