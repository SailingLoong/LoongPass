// Native regression fixture: no application services, accounts or preferences.
import 'dart:async';
import 'dart:io';

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/select_field_semantics.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.environment['SELECT_SMOKE_OWNER'] != 'platform') {
    SemanticsBinding.instance.ensureSemantics();
  }
  stdout.writeln('DART_START native=${WidgetsBinding.instance.platformDispatcher.semanticsEnabled} tree=${SemanticsBinding.instance.semanticsEnabled}');
  WidgetsBinding.instance.addSemanticsEnabledListener(() {
    stdout.writeln('DART_AX native=${WidgetsBinding.instance.platformDispatcher.semanticsEnabled} tree=${SemanticsBinding.instance.semanticsEnabled}');
  });
  if (Platform.environment['SELECT_SMOKE_ORDER'] == 'handshake') {
    final binding = SemanticsBinding.instance;
    final enabled = Completer<void>();
    void whenEnabled() {
      if (binding.semanticsEnabled && !enabled.isCompleted) enabled.complete();
    }
    binding.addSemanticsEnabledListener(whenEnabled);
    try {
      await const MethodChannel('loongpass.test/accessibility').invokeMethod<bool>('enableAccessibility');
      whenEnabled();
      await enabled.future.timeout(const Duration(seconds: 8));
      stdout.writeln('HANDSHAKE_READY native=${WidgetsBinding.instance.platformDispatcher.semanticsEnabled}');
    } finally {
      binding.removeSemanticsEnabledListener(whenEnabled);
    }
  }
  runApp(
    MaterialApp(
      localizationsDelegates: FLocalizations.localizationsDelegates,
      supportedLocales: FLocalizations.supportedLocales,
      builder: (context, child) =>
          FTheme(data: FTheme.neutral.light.desktop, child: child!),
      home: const _Smoke(),
    ),
  );
}

class _Smoke extends StatefulWidget {
  const _Smoke();
  @override
  State<_Smoke> createState() => _SmokeState();
}

class _SmokeState extends State<_Smoke> {
  var value = 'zcode';
  var ticks = 0;
  bool inspected = false;
  static const _probe = MethodChannel('loongpass.test/accessibility');

  @override
  void initState() {
    super.initState();
    Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (++ticks == 6) {
        timer.cancel();
        if (!const bool.fromEnvironment('LEGACY_SELECTOR') && !inspected)
          exit(2);
        stdout.writeln('NATIVE_SELECTOR_SMOKE_PASS');
        exit(0);
      }
      setState(() => value = ticks.isOdd ? 'workbuddy' : 'zcode');
      stdout.writeln('Changed selector: $value native=${WidgetsBinding.instance.platformDispatcher.semanticsEnabled} tree=${SemanticsBinding.instance.semanticsEnabled} lifecycle=${WidgetsBinding.instance.lifecycleState} frames=${WidgetsBinding.instance.framesEnabled}');
      if (!const bool.fromEnvironment('LEGACY_SELECTOR')) {
        if (ticks == 1) {
          final before = await _probe.invokeMapMethod<String, dynamic>('visibleTextFields');
          stdout.writeln('BEFORE_ROUTE $before');
        }
        if (ticks == 2 || ticks == 4) {
          unawaited(
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(builder: (_) => const _SearchPage()),
            ),
          );
        } else if (ticks == 3 || ticks == 5) {
          final snapshot = await _probe.invokeMapMethod<String, dynamic>(
            'visibleTextFields',
          );
          stdout.writeln('NATIVE_ACCESSIBILITY $snapshot');
          final roles = snapshot?['roles'] as List? ?? const [];
          final fields = snapshot?['sizedFields'] as int? ?? 0;
          if (fields == 0 || !roles.contains('AXTextField')) exit(3);
          inspected = true;
          stdout.writeln('NATIVE_TEXT_FIELD_FRAME_AND_ROLE $fields');
          if (mounted) Navigator.of(context).pop();
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SizedBox(
        width: 320,
        child: FSelect<String>(
          builder: const bool.fromEnvironment('LEGACY_SELECTOR')
              ? (context, style, variants, child) => child
              : selectFieldSemantics,
          items: const {'ZCode': 'zcode', 'WorkBuddy 国内版': 'workbuddy'},
          control: FSelectControl.lifted(
            value: value,
            onChange: (next) => setState(() => value = next!),
          ),
        ),
      ),
    ),
  );
}

class _SearchPage extends StatefulWidget {
  const _SearchPage();

  @override
  State<_SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<_SearchPage> {
  final suggestions = OverlayPortalController()..show();
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: OverlayPortal(
        controller: suggestions,
        overlayChildBuilder: (_) => const Align(
          alignment: Alignment.bottomCenter,
          child: Text('Search suggestions'),
        ),
        child: const SizedBox(width: 240, child: TextField(autofocus: true)),
      ),
    ),
  );
}
