import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:forui/forui.dart';

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
import 'invitation_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = UiPreferences.persistent();
  final invitations = {
    for (final app in InvitationSettings.platforms)
      app: InvitationSettings.persistent(app),
  };
  await Future.wait([
    preferences.load(),
    ...invitations.values.map((settings) => settings.load()),
  ]);
  runApp(AccountToolApp(preferences: preferences, invitations: invitations));
}

class AccountToolApp extends StatefulWidget {
  const AccountToolApp({super.key, this.preferences, this.invitations});
  final UiPreferences? preferences;
  final Map<ManagedApp, InvitationSettings>? invitations;
  @override
  State<AccountToolApp> createState() => _AccountToolAppState();
}

class _AccountToolAppState extends State<AccountToolApp> {
  late final _preferences = widget.preferences ?? UiPreferences();
  late final _invitations =
      widget.invitations ??
      {
        for (final app in InvitationSettings.platforms)
          app: InvitationSettings(app),
      };
  late final _home = _AccountPage(
    preferences: _preferences,
    invitations: _invitations,
  );
  @override
  void dispose() {
    if (widget.preferences == null) _preferences.dispose();
    if (widget.invitations == null) {
      for (final settings in _invitations.values) {
        settings.dispose();
      }
    }
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
      locale: const Locale('zh', 'CN'),
      localizationsDelegates: FLocalizations.localizationsDelegates,
      supportedLocales: FLocalizations.supportedLocales,
      builder: loongPassThemeBuilder,
      home: _home,
    ),
  );
}

/// Composition owns mounted platform pages; auxiliary pages only read UI snapshots.
class _AccountPage extends StatefulWidget {
  const _AccountPage({required this.preferences, required this.invitations});
  final UiPreferences preferences;
  final Map<ManagedApp, InvitationSettings> invitations;
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
          const Padding(padding: EdgeInsets.only(top: 12), child: FProgress()),
        if (_startError != null)
          FButton(
            variant: FButtonVariant.ghost,
            size: FButtonSizeVariant.sm,
            mainAxisSize: MainAxisSize.min,
            child: const Text('重试'),
            onPress: _starting ? null : _start,
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
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              app == ManagedApp.codex
                  ? CodexAccountsPanel(owner: _codex)
                  : _application == null
                  ? _status
                  : PluginAccountsPanel(
                      accounts: _application!.accounts,
                      rewards: _application!.rewards,
                      providerIds: providersForApp(app),
                      title: app.label,
                      registrationUrl: widget.invitations[app] == null
                          ? null
                          : () => widget.invitations[app]!.ready
                                ? widget.invitations[app]!.url
                                : null,
                      activate:
                          app == ManagedApp.workbuddy &&
                              workBuddyDesktopSupported
                          ? _application!.activateWorkBuddy
                          : null,
                    ),
            ],
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
  Widget build(BuildContext context) => FScaffold(
    childPad: false,
    child: SafeArea(
      child: AppWorkspace(
        key: _workspace,
        preferences: widget.preferences,
        initialApp: ManagedApp.workbuddy,
        footerBuilder: (context, compact) => AppUpdateBadge(
          updates: _updates,
          compact: compact,
          onOpen: () =>
              _workspace.currentState?.selectSection(WorkspaceSection.settings),
        ),
        pages: _pages,
        sections: {
          WorkspaceSection.models: _application == null
              ? _status
              : PluginModelServicesPage(application: _application!),
          WorkspaceSection.settings: WorkspaceSettingsPage(
            preferences: widget.preferences,
            updates: _updates,
            invitations: widget.invitations,
            onOpenApp: _openApp,
          ),
          WorkspaceSection.overview: WorkspaceOverviewPage(
            registry: _registry,
            onOpenApp: _openApp,
            serviceStatus: _application == null ? _status : null,
          ),
          WorkspaceSection.accounts: WorkspaceAccountsPage(
            registry: _registry,
            serviceStatus: _application == null ? _status : null,
          ),
          WorkspaceSection.activity: WorkspaceActivityPage(
            registry: _registry,
            serviceStatus: _application == null ? _status : null,
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
  Widget build(BuildContext context) => DefaultTextStyle(
    style: context.theme.typography.body.sm,
    child: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (showTitle) Text(name, style: context.theme.typography.display.xl),
        if (showTitle) const SizedBox(height: 8),
        panel,
      ],
    ),
  );
}
