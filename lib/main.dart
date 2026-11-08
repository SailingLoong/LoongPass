import 'dart:async';

import 'package:flutter/material.dart';

import 'desktop_platform.dart';
import 'app_theme.dart';
export 'app_theme.dart';
import 'app_sidebar.dart';
import 'codex_accounts.dart';
import 'codex_accounts_panel.dart';
import 'ui_preferences.dart';
import 'account_workspace_registry.dart';
import 'workspace_accounts.dart';
import 'workspace_tools.dart';
import 'app_updates.dart';
import 'plugin_application.dart';
import 'plugin_accounts_panel.dart';
import 'plugin_model_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = UiPreferences.persistent();
  await preferences.load();
  runApp(AccountToolApp(preferences: preferences));
}

class AccountToolApp extends StatefulWidget {
  const AccountToolApp({super.key, this.preferences});
  final UiPreferences? preferences;
  @override
  State<AccountToolApp> createState() => _AccountToolAppState();
}

class _AccountToolAppState extends State<AccountToolApp> {
  late final _preferences = widget.preferences ?? UiPreferences();
  late final _home = _AccountPage(preferences: _preferences);
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
  const _AccountPage({required this.preferences});
  final UiPreferences preferences;
  @override
  State<_AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<_AccountPage> {
  final _updates = AppUpdates();
  final _registry = AccountWorkspaceRegistry();
  final _codex = CodexAccounts();
  final _workspace = GlobalKey<AppWorkspaceState>();
  PluginApplication? _application;
  bool _starting = false;
  String? _startError;

  @override
  void initState() {
    super.initState();
    unawaited(_updates.load());
    unawaited(_codex.start());
    if (nativeAccountsSupported) unawaited(_start());
  }

  Future<void> _start() async {
    if (_starting || _application != null) return;
    setState(() {
      _starting = true;
      _startError = null;
    });
    try {
      final application = await PluginApplication.start();
      if (!mounted) {
        await application.close();
        return;
      }
      setState(() => _application = application);
    } catch (_) {
      if (mounted)
        setState(() => _startError = '账号服务未能启动。旧账号备份会保留，可检查网络与已有进程后重试。');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Widget get _status => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_starting ? '正在准备账号服务…' : _startError ?? '当前系统不支持原生账号服务。'),
        if (_starting)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(),
          ),
        if (_startError != null)
          TextButton(
            onPressed: _starting ? null : _start,
            child: const Text('重试'),
          ),
      ],
    ),
  );
  Map<ManagedApp, Widget> get _pages => {
    for (final app in ManagedApp.values)
      app: AccountPresentationScope(
        app: app,
        registry: _registry,
        child: AccountWorkspacePage(
          app.label,
          app == ManagedApp.codex
              ? CodexAccountsPanel(owner: _codex)
              : _application == null
              ? _status
              : PluginAccountsPanel(
                  accounts: _application!.accounts,
                  rewards: _application!.rewards,
                  providerIds: providersForApp(app),
                  title: app.label,
                  activate:
                      app == ManagedApp.workbuddy && workBuddyDesktopSupported
                      ? _application!.activateWorkBuddy
                      : null,
                ),
          showTitle: false,
        ),
      ),
  };
  void _openApp(ManagedApp app) => _workspace.currentState?.selectApp(app);
  @override
  void dispose() {
    _updates.dispose();
    _codex.dispose();
    if (_application != null) unawaited(_application!.close());
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
        pages: _pages,
        sections: {
          WorkspaceSection.models: _application == null
              ? _status
              : PluginModelServicesPage(application: _application!),
          WorkspaceSection.settings: WorkspaceSettingsPage(
            preferences: widget.preferences,
            updates: _updates,
          ),
          WorkspaceSection.overview: WorkspaceOverviewPage(
            registry: _registry,
            onOpenApp: _openApp,
            onOpenModels: () =>
                _workspace.currentState?.selectSection(WorkspaceSection.models),
          ),
          WorkspaceSection.accounts: WorkspaceAccountsPage(registry: _registry),
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
