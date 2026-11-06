import 'package:flutter/material.dart';
import 'app_sidebar.dart';
import 'qoder_device_panel.dart';
import 'qoder_device_accounts.dart';
import 'minimax_accounts_panel.dart';
import 'workbuddy_accounts_panel.dart';
import 'trae_accounts_panel.dart';
import 'zcode_accounts_panel.dart';

void main() => runApp(const AccountToolApp());

class AccountToolApp extends StatelessWidget {
  const AccountToolApp({super.key, this.workBuddyIdentityOnly = false});
  final bool workBuddyIdentityOnly;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'LoongPass',
    theme: loongPassTheme(Brightness.light),
    darkTheme: loongPassTheme(Brightness.dark),
    home: _AccountPage(identityValidationOnly: workBuddyIdentityOnly),
  );
}

/// Only account-related app workspaces are reachable from production navigation.
class _AccountPage extends StatelessWidget {
  const _AccountPage({this.identityValidationOnly = false});
  final bool identityValidationOnly;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: AppWorkspace(
        initialApp: ManagedApp.workbuddy,
        enabledApps: identityValidationOnly
            ? const {ManagedApp.workbuddy}
            : const {
                ManagedApp.zcode,
                ManagedApp.qoderCn,
                ManagedApp.qoder,
                ManagedApp.minimaxCn,
                ManagedApp.minimax,
                ManagedApp.workbuddy,
                ManagedApp.traeCn,
              },
        pages: {
          ManagedApp.zcode: identityValidationOnly
              ? const SizedBox.shrink()
              : AccountWorkspacePage('ZCode', const ZcodeAccountsPanel()),
          ManagedApp.qoderCn: identityValidationOnly
              ? const SizedBox.shrink()
              : AccountWorkspacePage(
                  'Qoder CN',
                  const QoderDeviceAccountsPanel(region: QoderRegion.cn),
                ),
          ManagedApp.qoder: identityValidationOnly
              ? const SizedBox.shrink()
              : AccountWorkspacePage(
                  'Qoder',
                  const QoderDeviceAccountsPanel(region: QoderRegion.global),
                ),
          ManagedApp.minimaxCn: identityValidationOnly
              ? const SizedBox.shrink()
              : AccountWorkspacePage(
                  'MiniMax CN',
                  const MiniMaxAccountsPanel(region: 'cn'),
                ),
          ManagedApp.minimax: identityValidationOnly
              ? const SizedBox.shrink()
              : AccountWorkspacePage(
                  'MiniMax',
                  const MiniMaxAccountsPanel(region: 'global'),
                ),
          ManagedApp.workbuddy: AccountWorkspacePage(
            'WorkBuddy',
            WorkBuddyAccountsPanel(savedAccounts: true),
          ),
          ManagedApp.traeCn: identityValidationOnly
              ? const SizedBox.shrink()
              : AccountWorkspacePage('TRAE CN', const TraeAccountsPanel()),
        },
      ),
    ),
  );
}

ThemeData loongPassTheme(Brightness brightness) {
  final colors = ColorScheme.fromSeed(
    seedColor: const Color(0xFF2863CE),
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    scaffoldBackgroundColor: colors.surface,
    visualDensity: VisualDensity.compact,
    textTheme: const TextTheme(
      bodyMedium: TextStyle(fontSize: 13),
      bodySmall: TextStyle(fontSize: 11),
      labelLarge: TextStyle(fontSize: 12),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceContainerLowest,
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(0, 32)),
    ),
  );
}

class AccountWorkspacePage extends StatelessWidget {
  const AccountWorkspacePage(this.name, this.panel, {super.key});
  final String name;
  final Widget panel;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text(
        name,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      panel,
    ],
  );
}
