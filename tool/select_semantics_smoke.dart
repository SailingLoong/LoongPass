// Native regression fixture: no application services, accounts or preferences.
import 'dart:async';
import 'dart:io';

import 'package:flutter/semantics.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/select_field_semantics.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SemanticsBinding.instance.ensureSemantics();
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

  @override
  void initState() {
    super.initState();
    Timer.periodic(const Duration(seconds: 1), (timer) {
      if (++ticks == 6) {
        stdout.writeln('NATIVE_SELECTOR_SMOKE_PASS');
        exit(0);
      }
      setState(() => value = ticks.isOdd ? 'workbuddy' : 'zcode');
      stdout.writeln('Changed selector: $value');
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
