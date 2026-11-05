import 'package:flutter/material.dart';
import 'app_sidebar.dart';
import 'qoder_device_panel.dart';
import 'qoder_device_accounts.dart';
import 'minimax_accounts_panel.dart';
import 'workbuddy_accounts_panel.dart';
import 'trae_accounts_panel.dart';

void main() => runApp(const AccountToolApp());

class AccountToolApp extends StatelessWidget {
  const AccountToolApp({super.key, this.workBuddyIdentityOnly = false});
  final bool workBuddyIdentityOnly;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'LoongPass',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF1664FF),
      ).copyWith(primary: const Color(0xFF1664FF), onPrimary: Colors.white),
      scaffoldBackgroundColor: const Color(0xFFF7F8FA),
      visualDensity: VisualDensity.compact,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFFE5E6EB)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
      ),
    ),
    home: _AccountPage(identityValidationOnly: workBuddyIdentityOnly),
  );
}

/// Only account-related app workspaces are reachable from production navigation.
class _AccountPage extends StatelessWidget {
  const _AccountPage({this.identityValidationOnly = false});
  final bool identityValidationOnly;

  Widget _appPage(String name, Widget panel) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text(
        name,
        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 6),
      const Text('同机账号管理', style: TextStyle(color: Color(0xFF86909C))),
      const SizedBox(height: 20),
      panel,
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: AppWorkspace(
        initialApp: ManagedApp.workbuddy,
        enabledApps: identityValidationOnly
            ? const {ManagedApp.workbuddy}
            : const {
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
              : _appPage(
                  'ZCode',
                  const Text(
                    'ZCode 凭证切换尚未接通。账号安全备份与恢复仅用于未来真实切换流程，不提供通用文件备份入口。',
                  ),
                ),
          ManagedApp.qoderCn: identityValidationOnly
              ? const SizedBox.shrink()
              : _appPage(
                  'Qoder CN',
                  const QoderDeviceAccountsPanel(region: QoderRegion.cn),
                ),
          ManagedApp.qoder: identityValidationOnly
              ? const SizedBox.shrink()
              : _appPage(
                  'Qoder',
                  const QoderDeviceAccountsPanel(region: QoderRegion.global),
                ),
          ManagedApp.minimaxCn: identityValidationOnly
              ? const SizedBox.shrink()
              : _appPage(
                  'MiniMax CN',
                  const MiniMaxAccountsPanel(region: 'cn'),
                ),
          ManagedApp.minimax: identityValidationOnly
              ? const SizedBox.shrink()
              : _appPage(
                  'MiniMax',
                  const MiniMaxAccountsPanel(region: 'global'),
                ),
          ManagedApp.workbuddy: _appPage(
            'WorkBuddy',
            WorkBuddyAccountsPanel(savedAccounts: true),
          ),
          ManagedApp.traeCn: identityValidationOnly
              ? const SizedBox.shrink()
              : _appPage('TRAE CN', const TraeAccountsPanel()),
        },
      ),
    ),
  );
}
