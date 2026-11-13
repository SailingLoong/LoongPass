import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;

import 'ui_preferences.dart';
import 'app_updates.dart';

class WorkspaceSettingsPage extends StatelessWidget {
  const WorkspaceSettingsPage({
    super.key,
    required this.preferences,
    this.updates,
  });
  final UiPreferences preferences;
  final AppUpdates? updates;
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: preferences,
      builder: (context, _) => WorkspacePage(
        title: '设置',
        subtitle: '外观、应用布局与更新。',
        children: [
          if (updates != null)
            WorkspaceCard(child: AppUpdateCard(updates: updates!)),
          if (preferences.error != null)
            WorkspaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(preferences.error!),
                  FButton(
                    variant: FButtonVariant.ghost,
                    size: FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    child: const Text('重新保存界面偏好'),
                    onPress: preferences.retrySave,
                  ),
                ],
              ),
            ),
          WorkspaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '外观与列表',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FSelect<ThemeMode>(
                        key: const Key('appearance-theme'),
                        label: const Text('主题'),
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
                      const SizedBox(height: 16),
                      FSelect<bool>(
                        key: const Key('account-row-density'),
                        label: const Text('账号行距'),
                        items: const {'紧凑': false, '舒适': true},
                        control: FSelectControl.lifted(
                          value: preferences.comfortable,
                          onChange: (value) {
                            if (value != null)
                              preferences.setComfortable(value);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                FSwitch(
                  value: preferences.collapsed,
                  label: const Text('精简应用栏'),
                  description: const Text('保留应用图标，悬停查看完整名称。'),
                  leadingLabel: true,
                  enabled: true,
                  onChange: preferences.setCollapsed,
                ),
              ],
            ),
          ),
          WorkspaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '应用排序',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                const Text('在左侧上下拖动应用。键盘聚焦应用后，也可用 Option + ↑ / ↓ 调整。顺序会保存在本机。'),
                FButton(
                  variant: FButtonVariant.ghost,
                  size: FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  child: const Text('恢复默认应用顺序'),
                  onPress: preferences.resetOrder,
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
                Text(
                  '授权以明文保存在本机应用私有目录。辅助签到与活动领取只在 LoongPass 运行期间执行；开关在各账号详情中设置。',
                ),
                SizedBox(height: 8),
                Text('界面偏好单独保存，不包含账号凭据、余额或领取记录。'),
              ],
            ),
          ),
        ],
      ),
    );
  }
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
  Widget build(BuildContext context) => ListView(
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
