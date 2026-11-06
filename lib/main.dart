import 'package:flutter/material.dart';
import 'app_theme.dart';
export 'app_theme.dart';
import 'app_sidebar.dart';
import 'qoder_device_panel.dart';
import 'qoder_device_accounts.dart';
import 'minimax_accounts_panel.dart';
import 'workbuddy_accounts_panel.dart';
import 'trae_accounts_panel.dart';
import 'zcode_accounts_panel.dart';
import 'ui_preferences.dart';
import 'account_workspace_registry.dart';
import 'workspace_accounts.dart';
import 'workspace_tools.dart';
import 'app_updates.dart';
import 'dart:async';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = UiPreferences.persistent();
  await preferences.load();
  runApp(AccountToolApp(preferences: preferences));
}

class AccountToolApp extends StatefulWidget {
  const AccountToolApp({
    super.key,
    this.workBuddyIdentityOnly = false,
    this.preferences,
  });
  final bool workBuddyIdentityOnly;
  final UiPreferences? preferences;
  @override
  State<AccountToolApp> createState() => _AccountToolAppState();
}

class _AccountToolAppState extends State<AccountToolApp> {
  late final _preferences = widget.preferences ?? UiPreferences();
  late final _home = _AccountPage(
    identityValidationOnly: widget.workBuddyIdentityOnly,
    preferences: _preferences,
  );
  @override
  void dispose() {
    if (widget.preferences == null) _preferences.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _preferences,
    builder: (context, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'LoongPass',
      theme: loongPassTheme(Brightness.light),
      darkTheme: loongPassTheme(Brightness.dark),
      themeMode: _preferences.themeMode,
      home: _home,
    ),
  );
}

/// Composition owns mounted platform pages; auxiliary pages only read UI snapshots.
class _AccountPage extends StatefulWidget {
  const _AccountPage({
    this.identityValidationOnly = false,
    required this.preferences,
  });
  final bool identityValidationOnly;
  final UiPreferences preferences;
  @override
  State<_AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<_AccountPage> {
  final _updates = AppUpdates();
  final _registry = AccountWorkspaceRegistry();
  final _workspace = GlobalKey<AppWorkspaceState>();
  late final Map<ManagedApp, Widget> _pages = {
    for (final entry in <ManagedApp, Widget>{
      ManagedApp.zcode: const ZcodeAccountsPanel(),
      ManagedApp.qoderCn: const QoderDeviceAccountsPanel(
        region: QoderRegion.cn,
      ),
      ManagedApp.qoder: const QoderDeviceAccountsPanel(
        region: QoderRegion.global,
      ),
      ManagedApp.minimaxCn: const MiniMaxAccountsPanel(region: 'cn'),
      ManagedApp.minimax: const MiniMaxAccountsPanel(region: 'global'),
      ManagedApp.workbuddy: const WorkBuddyAccountsPanel(savedAccounts: true),
      ManagedApp.traeCn: const TraeAccountsPanel(),
    }.entries)
      entry.key:
          widget.identityValidationOnly && entry.key != ManagedApp.workbuddy
          ? const SizedBox.shrink()
          : AccountPresentationScope(
              app: entry.key,
              registry: _registry,
              child: AccountWorkspacePage(
                entry.key.label,
                entry.value,
                showTitle: false,
              ),
            ),
  };
  void _openApp(ManagedApp app) => _workspace.currentState?.selectApp(app);
  @override
  void initState() {
    super.initState();
    if (!widget.identityValidationOnly) unawaited(_updates.load());
  }

  @override
  void dispose() {
    _updates.dispose();
    _registry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: AppWorkspace(
        key: _workspace,
        preferences: widget.preferences,
        initialApp: ManagedApp.workbuddy,
        enabledApps: widget.identityValidationOnly
            ? const {ManagedApp.workbuddy}
            : null,
        pages: _pages,
        sections: widget.identityValidationOnly
            ? const {}
            : {
                WorkspaceSection.settings: WorkspaceSettingsPage(
                  preferences: widget.preferences,
                  updates: _updates,
                ),
                WorkspaceSection.overview: WorkspaceOverviewPage(
                  registry: _registry,
                  onOpenApp: _openApp,
                  onOpenModels: () => _workspace.currentState?.selectSection(
                    WorkspaceSection.models,
                  ),
                ),
                WorkspaceSection.accounts: WorkspaceAccountsPage(
                  registry: _registry,
                ),
                WorkspaceSection.activity: WorkspaceActivityPage(
                  registry: _registry,
                  onOpenApp: _openApp,
                ),
              },
      ),
    ),
  );
}

class AccountWorkspacePage extends StatelessWidget {
  const AccountWorkspacePage(
    this.name,
    this.panel, {
    super.key,
    this.showTitle = true,
  });
  final String name;
  final Widget panel;
  final bool showTitle;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      if (showTitle)
        Text(name, style: Theme.of(context).textTheme.headlineSmall),
      if (showTitle) const SizedBox(height: 8),
      panel,
    ],
  );
}
