import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:forui/forui.dart';

import 'desktop_platform.dart';
import 'desktop_theme.dart';
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
import 'plugin_accounts.dart';
import 'plugin_accounts_panel.dart';
import 'plugin_model_page.dart';
import 'invitation_settings.dart';

const _appLocale = Locale('zh', 'CN');

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
  const AccountToolApp({
    super.key,
    this.preferences,
    this.invitations,
    this.application,
  });
  final UiPreferences? preferences;
  final Map<ManagedApp, InvitationSettings>? invitations;
  final PluginApplication? application;
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
    application: widget.application,
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
      locale: _appLocale,
      localizationsDelegates: FLocalizations.localizationsDelegates,
      supportedLocales: FLocalizations.supportedLocales,
      builder: loongPassThemeBuilder,
      home: _home,
    ),
  );
}

/// Composition owns mounted platform pages; auxiliary pages only read UI snapshots.
class _AccountPage extends StatefulWidget {
  const _AccountPage({
    required this.preferences,
    required this.invitations,
    this.application,
  });
  final UiPreferences preferences;
  final Map<ManagedApp, InvitationSettings> invitations;
  final PluginApplication? application;
  @override
  State<_AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<_AccountPage> {
  final _updates = AppUpdates();
  final _registry = AccountWorkspaceRegistry();
  final _codex = CodexAccounts();
  final _workspace = GlobalKey<AppWorkspaceState>();
  final _accountsPage = GlobalKey<WorkspaceAccountsPageState>();
  final _activityPage = GlobalKey<WorkspaceActivityPageState>();
  final _settingsTopic = ValueNotifier(SettingsSection.appearance);
  final _codexPanel = GlobalKey<CodexAccountsPanelState>();
  final _pluginPanels = {
    for (final app in ManagedApp.values.where((app) => app != ManagedApp.codex))
      app: GlobalKey<PluginAccountsPanelState>(),
  };
  PluginApplication? _application;
  String? _selectedModelId;
  bool _starting = false;
  String? _startError;

  @override
  void initState() {
    super.initState();
    unawaited(_updates.load());
    unawaited(_codex.start());
    _application = widget.application;
    _application?.models.addListener(_modelsChanged);
    if (_application == null && nativeAccountsSupported) unawaited(_start());
  }

  Future<void> _start() async {
    if (_starting || _application != null) return;
    setState(() {
      _starting = true;
      _startError = null;
    });
    try {
      final application = await PluginApplication.start(
        language: _appLocale.toLanguageTag(),
      );
      if (!mounted) {
        await application.close();
        return;
      }
      application.models.addListener(_modelsChanged);
      setState(() => _application = application);
    } catch (_) {
      if (mounted)
        setState(() => _startError = '账号服务未能启动。旧账号备份会保留，可检查网络与已有进程后重试。');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Widget get _status => Builder(
    builder: (context) => Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: context.desktopPalette.sidebar,
        borderRadius: context.theme.style.borderRadius.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _starting ? '正在准备账号服务' : '账号服务暂不可用',
            style: context.theme.typography.display.sm.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _starting ? '服务就绪后会显示本机已保存的账号。' : _startError ?? '当前系统不支持原生账号服务。',
            style: context.theme.typography.body.sm.copyWith(
              color: context.theme.colors.mutedForeground,
            ),
          ),
          if (_starting)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: FProgress(),
            ),
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
                  ? CodexAccountsPanel(key: _codexPanel, owner: _codex)
                  : _application == null
                  ? _status
                  : PluginAccountsPanel(
                      key: _pluginPanels[app],
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
  void _addAccount(ManagedApp app) {
    _workspace.currentState?.selectApp(app);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (app == ManagedApp.codex) {
        _codexPanel.currentState?.addAccount();
      } else {
        _pluginPanels[app]?.currentState?.addAccount();
      }
    });
  }

  void _openAccounts() =>
      _workspace.currentState?.selectSection(WorkspaceSection.accounts);
  void _openActivity() =>
      _workspace.currentState?.selectSection(WorkspaceSection.activity);
  void _openReceipts() {
    _openActivity();
    _activityPage.currentState?.showReceipts();
  }

  void _openUpdates() {
    _settingsTopic.value = SettingsSection.updates;
    _workspace.currentState?.selectSection(WorkspaceSection.settings);
  }

  void _modelsChanged() {
    if (!mounted) return;
    setState(() {
      if (_selectedModelId != 'auto' &&
          !_application!.models.catalog.any(
            (model) => model.id == _selectedModelId,
          )) {
        _selectedModelId = null;
      }
    });
  }

  void _selectModel(String? id) => setState(() => _selectedModelId = id);

  void _openAccount(PluginAccount account) {
    final app = ManagedApp.values
        .where((app) => app.nativeProviders.contains(account.provider))
        .firstOrNull;
    if (app == null) return;
    _workspace.currentState?.selectSection(WorkspaceSection.accounts);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted)
        _accountsPage.currentState?.revealAccount('${app.name}/${account.key}');
    });
  }

  @override
  void dispose() {
    _updates.dispose();
    _codex.dispose();
    _application?.models.removeListener(_modelsChanged);
    if (_application != null && widget.application == null)
      unawaited(_application!.close());
    _registry.dispose();
    _settingsTopic.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FScaffold(
    childPad: false,
    child: SafeArea(
      child: AppWorkspace(
        key: _workspace,
        preferences: widget.preferences,
        modelIds: [
          if (_application != null) 'auto',
          ...?_application?.models.catalog
              .where((model) => model.published)
              .map((model) => model.id),
        ],
        modelSearchTerms: {
          for (final model in _application?.models.catalog ?? [])
            model.id: model.searchText,
        },
        selectedModelId: _selectedModelId,
        onSelectModel: _selectModel,
        initialApp: ManagedApp.workbuddy,
        footerBuilder: (context, compact) => AppUpdateBadge(
          updates: _updates,
          compact: compact,
          onOpen: _openUpdates,
        ),
        pages: _pages,
        sections: {
          WorkspaceSection.models: _application == null
              ? WorkspacePage(title: '模型连接', children: [_status])
              : PluginModelServicesPage(
                  application: _application!,
                  selectedModelId: _selectedModelId,
                  onSelectModel: _selectModel,
                  onOpenAccount: _openAccount,
                ),
          WorkspaceSection.settings: WorkspaceSettingsPage(
            section: _settingsTopic,
            onOpenAccounts: _openAccounts,
            onOpenRewards: _openActivity,
            preferences: widget.preferences,
            updates: _updates,
            invitations: widget.invitations,
          ),
          WorkspaceSection.overview: WorkspaceOverviewPage(
            registry: _registry,
            onOpenApp: _addAccount,
            rewards: _application?.rewards,
            onOpenRewards: _openActivity,
            onOpenAccounts: _openAccounts,
            onOpenReceipts: _openReceipts,
            serviceStatus: _application == null ? _status : null,
          ),
          WorkspaceSection.accounts: WorkspaceAccountsPage(
            key: _accountsPage,
            registry: _registry,
            onOpenApp: _addAccount,
            serviceStatus: _application == null ? _status : null,
          ),
          WorkspaceSection.activity: WorkspaceActivityPage(
            key: _activityPage,
            registry: _registry,
            rewards: _application?.rewards,
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
      padding: EdgeInsets.fromLTRB(
        context.desktopGutter,
        26,
        context.desktopGutter,
        40,
      ),
      children: [
        if (showTitle) Text(name, style: context.theme.typography.display.xl),
        if (showTitle) const SizedBox(height: 8),
        panel,
      ],
    ),
  );
}
