// Native regression fixture: no application services, accounts or preferences.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/select_field_semantics.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // AppKit enables semantics after its native bridge exists. Let that signal
  // create the first tree, as in the desktop app.
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
      stdout.writeln('Changed selector: $value');
      if (!const bool.fromEnvironment('LEGACY_SELECTOR')) {
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
