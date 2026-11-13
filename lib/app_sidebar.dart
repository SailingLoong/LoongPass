import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'app_navigation_item.dart';
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
    setState(() {
      _selected = app;
      _all = false;
      _section = WorkspaceSection.accounts;
    });
  }

  void selectSection(WorkspaceSection section) =>
      setState(() => _section = section);
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
          final compact = constraints.maxWidth < 760 || _preferences.collapsed;
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
                  width: compact ? 56 : 176,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 14,
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
                                  Text(compact ? '展开导航' : '收起导航'),
                              child: FButton.icon(
                                key: const Key('toggle-sidebar'),
                                variant: FButtonVariant.ghost,
                                size: FButtonSizeVariant.sm,
                                semanticsLabel: compact ? '展开导航' : '收起导航',
                                onPress: constraints.maxWidth < 760
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
                        child: ListView(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          children: [
                            for (final section in order)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_section == WorkspaceSection.accounts)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 320),
                            child: FSelect<String>(
                              key: const Key('platform-filter'),
                              size: FTextFieldSizeVariant.sm,
                              items: {
                                if (widget.sections.containsKey(
                                  WorkspaceSection.accounts,
                                ))
                                  '全部平台': 'all',
                                for (final app in _preferences.appOrder)
                                  if (widget.enabledApps == null ||
                                      widget.enabledApps!.contains(app))
                                    '${app.label} · ${app.region}': app.name,
                              },
                              control: FSelectControl.lifted(
                                value: _all ? 'all' : _selected.name,
                                onChange: (value) {
                                  if (value == 'all')
                                    setState(() => _all = true);
                                  else if (value != null)
                                    selectApp(
                                      ManagedApp.values.firstWhere(
                                        (a) => a.name == value,
                                      ),
                                    );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    Expanded(
                      child: IndexedStack(
                        index: platformPage
                            ? _selected.index
                            : ManagedApp.values.length +
                                  order.indexOf(_section),
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
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
