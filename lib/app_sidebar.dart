import 'app_navigation_item.dart';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'managed_app.dart';
import 'ui_preferences.dart';
import 'workspace_tools.dart';
export 'managed_app.dart';

enum WorkspaceSection {
  overview('总览', FLucideIcons.layoutDashboard),
  accounts('账号与积分', FLucideIcons.wallet),
  models('模型服务', FLucideIcons.route),
  activity('活动记录', FLucideIcons.receiptText),
  settings('设置', FLucideIcons.slidersHorizontal);

  const WorkspaceSection(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Navigation never switches an account or runs I/O. Mounted page identity is
/// stable, independently of the user's sidebar order.
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
  WorkspaceSection? _section;
  late final UiPreferences _preferences = widget.preferences ?? UiPreferences();
  void selectApp(ManagedApp app) {
    if (widget.enabledApps != null && !widget.enabledApps!.contains(app))
      return;
    setState(() {
      _selected = app;
      _section = null;
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
          final brandIcon = Image.asset(
            'assets/branding/loongpass.png',
            width: 28,
            height: 28,
            excludeFromSemantics: true,
            filterQuality: FilterQuality.high,
          );
          final sections = {
            WorkspaceSection.settings: WorkspaceSettingsPage(
              preferences: _preferences,
            ),
            ...widget.sections,
          };
          final sectionOrder = WorkspaceSection.values
              .where(sections.containsKey)
              .toList();
          Widget sectionButton(WorkspaceSection section) =>
              SidebarNavigationButton(
                key: ValueKey('nav-${section.name}'),
                label: section.label,
                icon: Icon(section.icon, size: 17),
                compact: compact,
                selected: _section == section,
                onPressed: () => selectSection(section),
              );
          final toggle = FTooltip(
            tipBuilder: (context, controller) => Text(
              constraints.maxWidth < 760
                  ? 'LoongPass'
                  : compact
                  ? '展开应用栏'
                  : '收起应用栏',
            ),
            child: Semantics(
              tooltip: constraints.maxWidth < 760
                  ? 'LoongPass'
                  : compact
                  ? '展开应用栏'
                  : '收起应用栏',
              child: FButton.icon(
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                key: const Key('toggle-sidebar'),
                onPress: constraints.maxWidth < 760
                    ? null
                    : () => _preferences.setCollapsed(!_preferences.collapsed),
                child: compact
                    ? brandIcon
                    : const Icon(FLucideIcons.panelLeft, size: 19),
              ),
            ),
          );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ColoredBox(
                color: colors.muted,
                child: SizedBox(
                  key: const Key('app-sidebar'),
                  width: compact ? 64 : 196,
                  child: Column(
                    children: [
                      SizedBox(
                        height: 56,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Row(
                            children: [
                              if (!compact) ...[
                                brandIcon,
                                const SizedBox(width: 8),
                              ],
                              if (!compact)
                                Expanded(
                                  child: Text(
                                    'LoongPass',
                                    style: context.theme.typography.body.md
                                        .copyWith(fontWeight: FontWeight.w600),
                                  ),
                                ),
                              if (compact) Expanded(child: toggle) else toggle,
                            ],
                          ),
                        ),
                      ),
                      for (final section in [
                        WorkspaceSection.overview,
                        WorkspaceSection.accounts,
                      ])
                        if (sections.containsKey(section))
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: sectionButton(section),
                          ),
                      if (!compact)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 20, 12, 6),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '我的应用',
                              style: context.theme.typography.body.xs.copyWith(
                                color: colors.mutedForeground,
                              ),
                            ),
                          ),
                        ),
                      Expanded(
                        child: ReorderableList(
                          key: const Key('app-order'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 4,
                          ),
                          itemCount: _preferences.appOrder.length,
                          onReorderItem: _preferences.reorder,
                          proxyDecorator: (child, index, animation) =>
                              MouseRegion(
                                cursor: SystemMouseCursors.grabbing,
                                child: IgnorePointer(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: colors.muted,
                                      borderRadius:
                                          context.theme.style.borderRadius.xs,
                                      boxShadow: context.theme.style.shadow,
                                    ),
                                    child: child,
                                  ),
                                ),
                              ),
                          itemBuilder: (context, index) {
                            final app = _preferences.appOrder[index];
                            return AppNavigationItem(
                              key: ValueKey('ordered-${app.name}'),
                              app: app,
                              index: index,
                              compact: compact,
                              selected: _section == null && _selected == app,
                              onMove: (delta) =>
                                  _preferences.reorder(index, index + delta),
                              onPressed:
                                  widget.enabledApps == null ||
                                      widget.enabledApps!.contains(app)
                                  ? () => selectApp(app)
                                  : null,
                            );
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: FDivider(
                          style: FDividerStyleDelta.delta(
                            padding: const EdgeInsetsGeometryDelta.value(
                              EdgeInsets.symmetric(vertical: 6),
                            ),
                          ),
                        ),
                      ),
                      for (final section in [
                        WorkspaceSection.models,
                        WorkspaceSection.activity,
                        WorkspaceSection.settings,
                      ])
                        if (sections.containsKey(section))
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: sectionButton(section),
                          ),
                      if (widget.footerBuilder != null)
                        widget.footerBuilder!(context, compact),
                      if (_preferences.error != null)
                        FButton(
                          variant: FButtonVariant.ghost,
                          size: FButtonSizeVariant.sm,
                          mainAxisSize: MainAxisSize.min,
                          child: compact
                              ? const Icon(FLucideIcons.triangleAlert, size: 16)
                              : const Text('布局尚未保存'),
                          onPress: () =>
                              selectSection(WorkspaceSection.settings),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        child: FTooltip(
                          tipBuilder: (context, controller) =>
                              Text('账号保存在本机；辅助任务仅在运行期间执行'),
                          child: Semantics(
                            tooltip: '账号保存在本机；辅助任务仅在运行期间执行',
                            child: compact
                                ? const Icon(FLucideIcons.monitor, size: 15)
                                : Text(
                                    '账号保存在本机',
                                    style: context.theme.typography.body.xs
                                        .copyWith(
                                          color: colors.mutedForeground,
                                        ),
                                  ),
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
                  index: _section == null
                      ? _selected.index
                      : ManagedApp.values.length +
                            sectionOrder.indexOf(_section!),
                  sizing: StackFit.expand,
                  children: [
                    for (final app in ManagedApp.values)
                      KeyedSubtree(
                        key: ValueKey('page-${app.name}'),
                        child:
                            widget.pages[app] ??
                            Center(child: Text('${app.label} 尚未接入')),
                      ),
                    for (final section in sectionOrder)
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
