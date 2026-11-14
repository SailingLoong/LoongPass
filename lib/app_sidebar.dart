import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'app_navigation_item.dart';
import 'accounts_navigation.dart';
import 'managed_app.dart';
import 'ui_preferences.dart';
import 'workspace_tools.dart';
export 'managed_app.dart';

enum WorkspaceSection {
  overview('总览', FLucideIcons.layoutDashboard),
  accounts('账号与积分', FLucideIcons.wallet),
  models('模型连接', FLucideIcons.route),
  activity('最近领取', FLucideIcons.receiptText),
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
  });
  final Map<ManagedApp, Widget> pages;
  final ManagedApp initialApp;
  final Set<ManagedApp>? enabledApps;
  final UiPreferences? preferences;
  final Map<WorkspaceSection, Widget> sections;
  final Widget Function(BuildContext, bool compact)? footerBuilder;
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

  void selectApp(ManagedApp app) {
    if (widget.enabledApps != null && !widget.enabledApps!.contains(app))
      return;
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
    setState(() => _section = section);
  }

  void _selectAll() {
    setState(() {
      _all = true;
      _section = WorkspaceSection.accounts;
    });
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
          final automaticCompact = constraints.maxWidth < 900 * textScale;
          final compact = automaticCompact || _preferences.collapsed;
          final toggleLabel = automaticCompact
              ? '放大窗口以展开导航'
              : compact
              ? '展开导航'
              : '收起导航';
          final colors = context.theme.colors;
          final sections = {
            WorkspaceSection.accounts: const Center(child: Text('选择平台以管理账号。')),
            WorkspaceSection.settings: WorkspaceSettingsPage(
              preferences: _preferences,
              onOpenApp: selectApp,
            ),
            ...widget.sections,
          };
          final order = WorkspaceSection.values
              .where(sections.containsKey)
              .toList();
          final platformPage = _section == WorkspaceSection.accounts && !_all;
          final brand = Image.asset(
            'assets/branding/loongpass.png',
            width: 24,
            height: 24,
            excludeFromSemantics: true,
            filterQuality: FilterQuality.high,
          );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ColoredBox(
                color: colors.muted,
                child: SizedBox(
                  key: const Key('app-sidebar'),
                  width: compact ? 56 : 208 * textScale,
                  child: Column(
                    children: [
                      Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            if (!compact) ...[
                              brand,
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'LoongPass',
                                  style: context.theme.typography.body.sm
                                      .copyWith(fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                            FTooltip(
                              tipBuilder: (context, controller) =>
                                  Text(toggleLabel),
                              child: FButton.icon(
                                key: const Key('toggle-sidebar'),
                                variant: FButtonVariant.ghost,
                                size: FButtonSizeVariant.sm,
                                semanticsLabel: toggleLabel,
                                onPress: automaticCompact
                                    ? null
                                    : () => _preferences.setCollapsed(
                                        !_preferences.collapsed,
                                      ),
                                child: compact
                                    ? brand
                                    : const Icon(
                                        FLucideIcons.panelLeft,
                                        size: 16,
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final section in order)
                              if (section == WorkspaceSection.accounts)
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    child: AccountsNavigation(
                                      preferences: _preferences,
                                      compact: compact,
                                      active: _section == section,
                                      selectedApp: _all ? null : _selected,
                                      enabledApps: widget.enabledApps,
                                      onOpen: () => selectSection(section),
                                      onSelectAll: _selectAll,
                                      onSelectApp: selectApp,
                                      onHideApp: _hideApp,
                                    ),
                                  ),
                                )
                              else
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    8,
                                    0,
                                    8,
                                    4,
                                  ),
                                  child: SidebarNavigationButton(
                                    key: ValueKey('nav-${section.name}'),
                                    label: section.label,
                                    icon: Icon(section.icon, size: 18),
                                    compact: compact,
                                    selected: _section == section,
                                    onPressed: () => selectSection(section),
                                  ),
                                ),
                          ],
                        ),
                      ),
                      if (widget.footerBuilder != null)
                        widget.footerBuilder!(context, compact),
                      if (_preferences.error != null)
                        FButton(
                          variant: FButtonVariant.ghost,
                          size: FButtonSizeVariant.sm,
                          mainAxisSize: MainAxisSize.min,
                          onPress: () =>
                              selectSection(WorkspaceSection.settings),
                          child: compact
                              ? const Icon(FLucideIcons.triangleAlert, size: 16)
                              : const Text('布局尚未保存'),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: FTooltip(
                          tipBuilder: (context, controller) =>
                              const Text('账号保存在本机；自动任务仅在 LoongPass 运行期间执行'),
                          child: compact
                              ? const Icon(FLucideIcons.monitor, size: 16)
                              : Text(
                                  '账号保存在本机',
                                  style: context.theme.typography.body.xs
                                      .copyWith(color: colors.mutedForeground),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const FDivider(
                axis: Axis.vertical,
                style: FDividerStyleDelta.delta(
                  padding: EdgeInsetsGeometryDelta.value(EdgeInsets.zero),
                ),
              ),
              Expanded(
                child: IndexedStack(
                  index: platformPage
                      ? _selected.index
                      : ManagedApp.values.length + order.indexOf(_section),
                  sizing: StackFit.expand,
                  children: [
                    for (final app in ManagedApp.values)
                      KeyedSubtree(
                        key: ValueKey('page-${app.name}'),
                        child:
                            widget.pages[app] ??
                            Center(child: Text('${app.label} 尚未接入')),
                      ),
                    for (final section in order)
                      KeyedSubtree(
                        key: ValueKey('section-${section.name}'),
                        child: sections[section]!,
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
