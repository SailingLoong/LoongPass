import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;

import 'ui_preferences.dart';
import 'app_updates.dart';
import 'managed_app.dart';
import 'app_navigation_item.dart';
import 'invitation_settings.dart';
import 'invitation_settings_panel.dart';

class WorkspaceSettingsPage extends StatefulWidget {
  const WorkspaceSettingsPage({
    super.key,
    required this.preferences,
    this.updates,
    this.invitations = const {},
    this.onOpenApp,
  });
  final UiPreferences preferences;
  final AppUpdates? updates;
  final Map<ManagedApp, InvitationSettings> invitations;
  final ValueChanged<ManagedApp>? onOpenApp;
  @override
  State<WorkspaceSettingsPage> createState() => _WorkspaceSettingsPageState();
}

class _WorkspaceSettingsPageState extends State<WorkspaceSettingsPage> {
  final _expanded = <int>{};
  UiPreferences get preferences => widget.preferences;
  AppUpdates? get updates => widget.updates;
  Map<ManagedApp, InvitationSettings> get invitations => widget.invitations;
  ValueChanged<ManagedApp>? get onOpenApp => widget.onOpenApp;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: preferences,
    builder: (context, _) => WorkspacePage(
      title: '设置',
      subtitle: '外观、平台偏好、运行与更新。',
      children: [
        if (preferences.error != null)
          WorkspaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(preferences.error!),
                FButton(
                  variant: FButtonVariant.outline,
                  size: FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  onPress: preferences.retrySave,
                  child: const Text('重新保存界面偏好'),
                ),
              ],
            ),
          ),
        WorkspaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '外观与列表',
                style: context.theme.typography.body.sm.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              LayoutBuilder(
                builder: (context, box) {
                  final fields = [
                    FSelect<ThemeMode>(
                      key: const Key('appearance-theme'),
                      label: const Text('主题'),
                      size: FTextFieldSizeVariant.sm,
                      items: const {
                        '跟随系统': ThemeMode.system,
                        '浅色': ThemeMode.light,
                        '深色': ThemeMode.dark,
                      },
                      control: FSelectControl.lifted(
                        value: preferences.themeMode,
                        onChange: (value) {
                          if (value != null) preferences.setTheme(value);
                        },
                      ),
                    ),
                    FSelect<bool>(
                      key: const Key('account-row-density'),
                      label: const Text('账号行距'),
                      size: FTextFieldSizeVariant.sm,
                      items: const {'紧凑': false, '舒适': true},
                      control: FSelectControl.lifted(
                        value: preferences.comfortable,
                        onChange: (value) {
                          if (value != null) preferences.setComfortable(value);
                        },
                      ),
                    ),
                  ];
                  return box.maxWidth >=
                          440 * MediaQuery.textScalerOf(context).scale(14) / 14
                      ? Row(
                          children: [
                            Expanded(child: fields[0]),
                            const SizedBox(width: 20),
                            Expanded(child: fields[1]),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            fields[0],
                            const SizedBox(height: 16),
                            fields[1],
                          ],
                        );
                },
              ),
              const SizedBox(height: 16),
              FSwitch(
                value: preferences.collapsed,
                label: const Text('精简导航'),
                description: const Text('只显示任务图标，悬停可查看名称。'),
                leadingLabel: true,
                onChange: preferences.setCollapsed,
              ),
            ],
          ),
        ),
        WorkspaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '平台偏好',
                style: context.theme.typography.body.sm.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              FAccordion(
                control: FAccordionControl.lifted(
                  expanded: _expanded.contains,
                  onChange: (index, value) => setState(() {
                    value ? _expanded.add(index) : _expanded.remove(index);
                  }),
                ),
                children: [
                  FAccordionItem(
                    key: const Key('platform-order-settings'),
                    title: const Text('平台顺序'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('拖动调整账号页的平台选择顺序，也可聚焦后用 Option + ↑ / ↓ 调整。'),
                        const SizedBox(height: 8),
                        ReorderableList(
                          key: const Key('app-order'),
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: preferences.appOrder.length,
                          onReorderItem: preferences.reorder,
                          proxyDecorator: (child, index, animation) =>
                              MouseRegion(
                                cursor: SystemMouseCursors.grabbing,
                                child: ColoredBox(
                                  color: context.theme.colors.muted,
                                  child: child,
                                ),
                              ),
                          itemBuilder: (context, index) {
                            final app = preferences.appOrder[index];
                            return AppNavigationItem(
                              key: ValueKey('ordered-${app.name}'),
                              app: app,
                              index: index,
                              compact: false,
                              selected: false,
                              onMove: (delta) =>
                                  preferences.reorder(index, index + delta),
                              onPressed: onOpenApp == null
                                  ? null
                                  : () => onOpenApp!(app),
                            );
                          },
                        ),
                        FButton(
                          variant: FButtonVariant.ghost,
                          size: FButtonSizeVariant.sm,
                          mainAxisSize: MainAxisSize.min,
                          onPress: preferences.resetOrder,
                          child: const Text('恢复默认应用顺序'),
                        ),
                      ],
                    ),
                  ),
                  for (final entry in invitations.entries)
                    FAccordionItem(
                      key: ValueKey('invitation-${entry.key.name}'),
                      title: Text('${entry.key.label} 邀请设置'),
                      child: InvitationSettingsPanel(
                        key: ValueKey(entry.key),
                        settings: entry.value,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const WorkspaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('运行与数据', style: TextStyle(fontWeight: FontWeight.w600)),
              SizedBox(height: 8),
              Text('自动签到与活动领取仅在 LoongPass 运行期间执行。各账号详情保留独立开关和最近结果。'),
              SizedBox(height: 8),
              Text('授权以明文保存在本机应用私有目录。界面偏好单独保存，不包含凭据、余额或领取记录。'),
            ],
          ),
        ),
        if (updates != null)
          WorkspaceCard(child: AppUpdateCard(updates: updates!)),
      ],
    ),
  );
}

class WorkspacePage extends StatelessWidget {
  const WorkspacePage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
  });
  final String title, subtitle;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => DefaultTextStyle(
    style: context.theme.typography.body.sm,
    child: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(title, style: context.theme.typography.display.xl),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: context.theme.typography.body.xs.copyWith(
            color: context.theme.colors.mutedForeground,
          ),
        ),
        const SizedBox(height: 20),
        ...children,
      ],
    ),
  );
}

class WorkspaceCard extends StatelessWidget {
  const WorkspaceCard({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: FCard(
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  );
}
