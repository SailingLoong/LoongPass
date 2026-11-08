import 'package:flutter/material.dart';

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
    final selectorWidth = MediaQuery.textScalerOf(context).scale(100) + 32;
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
                  TextButton(
                    onPressed: preferences.retrySave,
                    child: const Text('重新保存界面偏好'),
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
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('主题'),
                  trailing: SizedBox(
                    width: selectorWidth,
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<ThemeMode>(
                          value: preferences.themeMode,
                          isDense: true,
                          isExpanded: true,
                          items: const [
                            DropdownMenuItem(
                              value: ThemeMode.system,
                              child: Text('跟随系统'),
                            ),
                            DropdownMenuItem(
                              value: ThemeMode.light,
                              child: Text('浅色'),
                            ),
                            DropdownMenuItem(
                              value: ThemeMode.dark,
                              child: Text('深色'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v != null) preferences.setTheme(v);
                          },
                        ),
                      ),
                    ),
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('账号行距'),
                  trailing: SizedBox(
                    width: selectorWidth,
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<bool>(
                          value: preferences.comfortable,
                          isDense: true,
                          isExpanded: true,
                          items: const [
                            DropdownMenuItem(value: false, child: Text('紧凑')),
                            DropdownMenuItem(value: true, child: Text('舒适')),
                          ],
                          onChanged: (v) {
                            if (v != null) preferences.setComfortable(v);
                          },
                        ),
                      ),
                    ),
                  ),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('精简应用栏'),
                  subtitle: const Text('保留应用图标，悬停查看完整名称。'),
                  value: preferences.collapsed,
                  onChanged: preferences.setCollapsed,
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
                TextButton(
                  onPressed: preferences.resetOrder,
                  child: const Text('恢复默认应用顺序'),
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
    padding: const EdgeInsets.all(24),
    children: [
      Text(title, style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 6),
      Text(
        subtitle,
        style: Theme.of(context).textTheme.bodyLarge!.copyWith(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
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
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(padding: const EdgeInsets.all(18), child: child),
  );
}
