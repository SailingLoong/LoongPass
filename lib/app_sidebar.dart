import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:material_ui/material_ui.dart'
    show Drawer, MaterialPage, Scaffold, ScaffoldState;

import 'desktop_theme.dart';
import 'workspace_toolbar.dart';
import 'app_navigation_item.dart';
import 'accounts_navigation.dart';
import 'models_navigation.dart';
import 'managed_app.dart';
import 'ui_preferences.dart';
import 'workspace_tools.dart';
export 'managed_app.dart';

enum WorkspaceSection {
  overview('总览', FLucideIcons.layoutDashboard),
  accounts('账号与积分', FLucideIcons.wallet),
  models('模型连接', FLucideIcons.route),
  activity('辅助签到', FLucideIcons.calendarCheck),
  settings('设置', FLucideIcons.slidersHorizontal);

  const WorkspaceSection(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Navigation owns only view state. Every platform remains mounted so drafts,
/// account owners and in-progress operations survive navigation unchanged.
class AppWorkspace extends StatefulWidget {
  const AppWorkspace({
    super.key,
    required this.pages,
    this.initialApp = ManagedApp.zcode,
    this.enabledApps,
    this.preferences,
    this.sections = const {},
    this.footerBuilder,
    this.modelIds = const [],
    this.selectedModelId,
    this.onSelectModel,
  });
  final Map<ManagedApp, Widget> pages;
  final ManagedApp initialApp;
  final Set<ManagedApp>? enabledApps;
  final UiPreferences? preferences;
  final Map<WorkspaceSection, Widget> sections;
  final Widget Function(BuildContext, bool compact)? footerBuilder;
  final List<String> modelIds;
  final String? selectedModelId;
  final ValueChanged<String?>? onSelectModel;
  @override
  State<AppWorkspace> createState() => AppWorkspaceState();
}

class AppWorkspaceState extends State<AppWorkspace> {
  late ManagedApp _selected = widget.initialApp;
  late bool _all = widget.sections.containsKey(WorkspaceSection.accounts);
  late WorkspaceSection _section =
      widget.sections.containsKey(WorkspaceSection.overview)
      ? WorkspaceSection.overview
      : WorkspaceSection.accounts;
  late final UiPreferences _preferences = widget.preferences ?? UiPreferences();

  final _shell = GlobalKey<ScaffoldState>();
  final _contentNavigator = GlobalKey<NavigatorState>();
  bool? _compactOverride;
  void _returnToSection() =>
      _contentNavigator.currentState?.popUntil((route) => route.isFirst);

  void selectApp(ManagedApp app) {
    if (widget.enabledApps != null && !widget.enabledApps!.contains(app))
      return;
    _returnToSection();
    _shell.currentState?.closeDrawer();
    _preferences.setAppVisible(app, true);
    _preferences.setAppsExpanded(true);
    setState(() {
      _selected = app;
      _all = false;
      _section = WorkspaceSection.accounts;
    });
  }

  void selectSection(WorkspaceSection section) {
    if (section == WorkspaceSection.accounts)
      _preferences.setAppsExpanded(true);
    if (section == WorkspaceSection.models)
      _preferences.setModelsExpanded(true);
    _returnToSection();
    _shell.currentState?.closeDrawer();
    setState(() {
      if (section == WorkspaceSection.accounts) _all = true;
      _section = section;
    });
  }

  void selectModel(String? id) {
    widget.onSelectModel?.call(id);
    selectSection(WorkspaceSection.models);
  }

  Widget _modelsNavigation(bool compact) => ModelsNavigation(
    preferences: _preferences,
    compact: compact,
    active: _section == WorkspaceSection.models,
    modelIds: widget.modelIds,
    selectedModelId: widget.selectedModelId,
    onOpen: () => selectModel(null),
    onSelectModel: selectModel,
  );

  Widget _navigation(WorkspaceSection section, bool compact) {
    final child = switch (section) {
      WorkspaceSection.accounts => AccountsNavigation(
        preferences: _preferences,
        compact: compact,
        active: _section == section,
        selectedApp: _all ? null : _selected,
        enabledApps: widget.enabledApps,
        onOpen: () => selectSection(section),
        onSelectApp: selectApp,
        onHideApp: _hideApp,
      ),
      WorkspaceSection.models => _modelsNavigation(compact),
      _ => SidebarNavigationButton(
        key: ValueKey('nav-${section.name}'),
        label: section.label,
        icon: Icon(section.icon, size: 18),
        compact: compact,
        selected: _section == section,
        onPressed: () => selectSection(section),
      ),
    };
    final entry = Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: child,
    );
    final expanded = switch (section) {
      WorkspaceSection.accounts => _preferences.appsExpanded,
      WorkspaceSection.models => !compact && _preferences.modelsExpanded,
      _ => false,
    };
    // Primary entries keep their height. Only the open child list can scroll
    // within the space left over, and short lists keep their natural height.
    return expanded && section == _section ? Flexible(child: entry) : entry;
  }

  void _hideApp(ManagedApp app) {
    if (_selected == app) setState(() => _all = true);
    _preferences.setAppVisible(app, false);
  }

  @override
  void dispose() {
    if (widget.preferences == null) _preferences.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UiPreferencesScope(
    preferences: _preferences,
    child: ListenableBuilder(
      listenable: _preferences,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14)
              .clamp(1.0, double.infinity);
          final narrow = constraints.maxWidth < 620;
          final compact =
              !narrow &&
              (_compactOverride ?? (constraints.maxWidth < 620 * textScale));
          final colors = context.theme.colors;
          final sections = {
            WorkspaceSection.accounts: const Center(child: Text('选择平台以管理账号。')),
            WorkspaceSection.settings: WorkspaceSettingsPage(
              preferences: _preferences,
            ),
            ...widget.sections,
          };
          final order = WorkspaceSection.values
              .where(sections.containsKey)
              .toList();
          final platformPage = _section == WorkspaceSection.accounts && !_all;
          final brand = Image.asset(
            'assets/branding/loongpass.png',
            key: const Key('app-brand'),
            width: 30,
            height: 30,
            excludeFromSemantics: true,
            filterQuality: FilterQuality.high,
          );
          final sidebarWidth = narrow
              ? (264 * textScale)
                    .clamp(0, constraints.maxWidth * .86)
                    .toDouble()
              : compact
              ? 56.0
              : (constraints.maxWidth <= 1088 ? 196 : 201.6) * textScale;
          final sidebar = DecoratedBox(
            decoration: BoxDecoration(
              color: context.desktopPalette.sidebar,
              border: Border(right: BorderSide(color: colors.border)),
            ),
            child: SizedBox(
              key: const Key('app-sidebar'),
              width: sidebarWidth,
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 8 : 18,
                      vertical: constraints.maxHeight < 500 ? 8 : 30,
                    ),
                    child: Row(
                      mainAxisAlignment: compact
                          ? MainAxisAlignment.center
                          : MainAxisAlignment.start,
                      children: [
                        brand,
                        if (!compact) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'LoongPass',
                              style: context.theme.typography.body.sm.copyWith(
                                fontSize: 21,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -1,
                              ),
                            ),
                          ),
                        ],
                        if (narrow)
                          FButton.icon(
                            variant: FButtonVariant.ghost,
                            semanticsLabel: '收起主导航',
                            onPress: () => _shell.currentState?.closeDrawer(),
                            child: const Icon(FLucideIcons.x, size: 16),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final section in order.where(
                          (s) => s != WorkspaceSection.settings,
                        ))
                          _navigation(section, compact),
                      ],
                    ),
                  ),
                  _navigation(WorkspaceSection.settings, compact),
                  if (widget.footerBuilder != null)
                    widget.footerBuilder!(context, compact),
                  if (_preferences.error != null)
                    FButton(
                      variant: FButtonVariant.ghost,
                      size: FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: () => selectSection(WorkspaceSection.settings),
                      child: compact
                          ? const Icon(FLucideIcons.triangleAlert, size: 16)
                          : const Text('布局尚未保存'),
                    ),
                  const SizedBox(height: 6),
                ],
              ),
            ),
          );
          // Hide a page's tooltips and menus in the same frame as their anchors.
          final pages = IndexedStack(
            index: platformPage
                ? _selected.index
                : ManagedApp.values.length + order.indexOf(_section),
            sizing: StackFit.expand,
            children: [
              for (final app in ManagedApp.values)
                Overlay.wrap(
                  key: ValueKey('page-${app.name}'),
                  child:
                      widget.pages[app] ??
                      Center(child: Text('${app.label} 尚未接入')),
                ),
              for (final section in order)
                Overlay.wrap(
                  key: ValueKey('section-${section.name}'),
                  child: sections[section]!,
                ),
            ],
          );
          return Scaffold(
            key: _shell,
            backgroundColor: colors.background,
            drawer: narrow ? Drawer(width: sidebarWidth, child: sidebar) : null,
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!narrow) sidebar,
                Expanded(
                  key: const ValueKey('workspace-body'),
                  child: Column(
                    children: [
                      WorkspaceToolbar(
                        narrow: narrow,
                        action: narrow
                            ? widget.footerBuilder?.call(context, true)
                            : null,
                        onToggle: () {
                          if (narrow) {
                            _shell.currentState?.openDrawer();
                          } else {
                            setState(() => _compactOverride = !compact);
                          }
                        },
                      ),
                      Expanded(
                        child: NavigatorPopHandler<void>(
                          onPopWithResult: (_) =>
                              _contentNavigator.currentState?.maybePop(),
                          child: Semantics(
                            container: true,
                            explicitChildNodes: true,
                            child: Navigator(
                              key: _contentNavigator,
                              pages: [
                                MaterialPage<void>(
                                  key: const ValueKey('workspace-root'),
                                  child: pages,
                                ),
                              ],
                              onDidRemovePage: (_) {},
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}
