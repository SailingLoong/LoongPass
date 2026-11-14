import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/magpie_connection.dart';
import '../lib/model_connection.dart';
import '../lib/model_connection_panel.dart';
import '../lib/plugin_accounts.dart';
import '../lib/plugin_model_service.dart';
import 'desktop_test_app.dart';
import 'magpie_fixture.dart';

class _Models extends ChangeNotifier implements PluginModelService {
  @override
  bool get enabled => true;
  @override
  bool get running => true;
  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:3426');
  @override
  final grants = [
    PluginModelGrant(
      PluginAccount(
        key: 'one',
        active: true,
        facts: {'registrationId': 'one'},
        models: [],
      ),
      'private-grant',
      true,
    ),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testDesktopWidgets(
    'opening and rebuilding are passive; explicit check can recover',
    (tester) async {
      final models = _Models();
      var calls = 0, offline = true;
      final connection = ModelConnection(
        models,
        '/bridge',
        client: MagpieConnection(
          run: (args, {input}) async {
            calls++;
            if (args.first == 'healthcheck') {
              if (offline) throw StateError('private-grant');
              return '';
            }
            return jsonEncode(magpiePluginList(['one']));
          },
        ),
      );
      addTearDown(models.dispose);
      addTearDown(connection.dispose);
      Widget page() => DesktopTestApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ModelConnectionPanel(connection: connection),
          ),
        ),
      );
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      await tester.pumpWidget(page());
      expect(calls, 0);
      await tester.tap(find.text('检查连接'));
      await tester.pumpAndSettle();
      expect(find.textContaining('网关不可达'), findsOneWidget);
      expect(find.textContaining('1 / 1'), findsOneWidget);
      expect(find.textContaining('private-grant'), findsNothing);
      offline = false;
      await tester.tap(find.text('重新检查'));
      await tester.pumpAndSettle();
      expect(find.textContaining('网关可达'), findsOneWidget);
      expect(calls, 4);
    },
  );

  testDesktopWidgets(
    'guide opens through native bridge; narrow large text remains usable',
    (tester) async {
      tester.view.physicalSize = const Size(480, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final models = _Models();
      final connection = ModelConnection(models, '/bridge');
      addTearDown(models.dispose);
      addTearDown(connection.dispose);
      final links = <String>[];
      const channel = MethodChannel('com.sailingloong.loongpass/files');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'openExternalHTTPS');
            links.add((call.arguments as Map)['url'] as String);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await tester.pumpWidget(
        DesktopTestApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ModelConnectionPanel(connection: connection),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('DeepSeek Harness · Agent Teams'));
      await tester.tap(find.text('DeepSeek Harness · Agent Teams'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('打开接入指南'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开接入指南'));
      await tester.pumpAndSettle();
      expect(links, [
        'https://github.com/SailingLoong/LoongPass/blob/main/docs/dsh-multi-agent.md',
      ]);
      expect(find.textContaining('Use Agent Teams'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
