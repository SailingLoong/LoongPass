import 'app_navigation_item.dart';
import 'package:flutter/material.dart';
import 'managed_app.dart';
import 'ui_preferences.dart';
import 'workspace_tools.dart';
export 'managed_app.dart';

enum WorkspaceSection {
  overview('总览', Icons.space_dashboard_outlined),
  accounts('账号与积分', Icons.account_balance_wallet_outlined),
  models('模型服务', Icons.route_outlined),
  activity('活动记录', Icons.receipt_long_outlined),
  settings('设置', Icons.tune);

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
  });
  final Map<ManagedApp, Widget> pages;
  final ManagedApp initialApp;
  final Set<ManagedApp>? enabledApps;
  final UiPreferences? preferences;
  final Map<WorkspaceSection, Widget> sections;
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
          final colors = Theme.of(context).colorScheme;
          final sections = {
            WorkspaceSection.models: const ModelServicesPage(),
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
                icon: Icon(section.icon, size: 19),
                compact: compact,
                selected: _section == section,
                onPressed: () => selectSection(section),
              );
          final toggle = IconButton(
            key: const Key('toggle-sidebar'),
            tooltip: constraints.maxWidth < 760
                ? 'LoongPass'
                : compact
                ? '展开应用栏'
                : '收起应用栏',
            onPressed: constraints.maxWidth < 760
                ? null
                : () => _preferences.setCollapsed(!_preferences.collapsed),
            style: IconButton.styleFrom(
              fixedSize: const Size(30, 30),
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            icon: const Icon(Icons.view_sidebar_outlined, size: 19),
          );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Material(
                color: colors.surfaceContainerLow,
                child: SizedBox(
                  key: const Key('app-sidebar'),
                  width: compact ? 64 : 196,
                  child: Column(
                    children: [
                      SizedBox(
                        height: 48,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Row(
                            children: [
                              if (!compact)
                                const Expanded(
                                  child: Text(
                                    'LoongPass',
                                    style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700,
                                    ),
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
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 12, 12, 6),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '我的应用',
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(0xFF86909C),
                              ),
                            ),
                          ),
                        ),
                      Expanded(
                        child: ReorderableListView.builder(
                          key: const Key('app-order'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 4,
                          ),
                          buildDefaultDragHandles: false,
                          itemCount: _preferences.appOrder.length,
                          onReorderItem: _preferences.reorder,
                          proxyDecorator: (child, index, animation) => Material(
                            elevation: 4,
                            color: colors.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(6),
                            child: child,
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
                      Divider(
                        height: 12,
                        indent: 12,
                        endIndent: 12,
                        color: colors.outlineVariant,
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
                      if (_preferences.error != null)
                        TextButton(
                          onPressed: () =>
                              selectSection(WorkspaceSection.settings),
                          child: compact
                              ? const Icon(Icons.warning_amber, size: 16)
                              : const Text('布局尚未保存'),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        child: Tooltip(
                          message: '账号保存在本机；自动任务仅在运行期间执行',
                          child: compact
                              ? const Icon(Icons.computer_outlined, size: 15)
                              : Text(
                                  '本机保存 · 开发预览',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              VerticalDivider(
                width: 1,
                thickness: 1,
                color: colors.outlineVariant,
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
