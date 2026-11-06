import 'package:flutter/material.dart';
import 'ui_preferences.dart';

class ModelServicesPage extends StatelessWidget {
  const ModelServicesPage({super.key});
  @override
  Widget build(BuildContext context) => WorkspacePage(
    title: '模型服务',
    subtitle: '让其他软件使用已保存账号的模型能力。',
    children: [
      WorkspaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.route_outlined, size: 22),
                SizedBox(width: 10),
                Text(
                  'Magpie',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                Spacer(),
                Chip(label: Text('尚未接入')),
              ],
            ),
            const SizedBox(height: 12),
            const Text('当前版本可以管理账号与积分，尚未提供供 Magpie 调用的模型接口。'),
            const SizedBox(height: 8),
            Text(
              '保存账号不会自动开放模型调用，也不会自动消耗积分。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              icon: const Icon(Icons.info_outline, size: 17),
              label: const Text('查看 Magpie 接入说明'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Magpie 接入说明'),
                  content: const SizedBox(
                    width: 440,
                    child: Text(
                      '接入能力完成后，这里会提供实际的连接地址、访问密钥和已验证的模型列表，并允许设置平台与账号的使用顺序。\n\n当前没有可用的连接配置。账号列表中的余额和领取功能不代表这些账号已能供其他软件调用。',
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      const WorkspaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('积分使用顺序', style: TextStyle(fontWeight: FontWeight.w600)),
            SizedBox(height: 8),
            Text('在实际模型来源接入并验证后开放。应用栏的拖拽只调整导航顺序，不改变积分消耗顺序。'),
          ],
        ),
      ),
    ],
  );
}

class WorkspaceSettingsPage extends StatelessWidget {
  const WorkspaceSettingsPage({super.key, required this.preferences});
  final UiPreferences preferences;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: preferences,
    builder: (context, _) => WorkspacePage(
      title: '设置',
      subtitle: '让 LoongPass 按你的习惯显示。',
      children: [
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
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('主题'),
                  DropdownButton<ThemeMode>(
                    value: preferences.themeMode,
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
                  const Text('账号行距'),
                  DropdownButton<bool>(
                    value: preferences.comfortable,
                    items: const [
                      DropdownMenuItem(value: false, child: Text('紧凑')),
                      DropdownMenuItem(value: true, child: Text('舒适')),
                    ],
                    onChanged: (v) {
                      if (v != null) preferences.setComfortable(v);
                    },
                  ),
                ],
              ),
              SwitchListTile(
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
              const Text('应用排序', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              const Text('在左侧上下拖动应用。键盘聚焦应用后，也可用 ⌥↑ / ⌥↓ 调整。顺序会保存在本机。'),
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
              Text('授权以明文保存在本机应用私有目录。自动签到与活动领取只在 LoongPass 运行期间执行；开关在各账号详情中设置。'),
              SizedBox(height: 8),
              Text('界面偏好单独保存，不包含账号凭据、余额或领取记录。'),
            ],
          ),
        ),
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
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text(
        title,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 6),
      Text(
        subtitle,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
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
    margin: const EdgeInsets.only(bottom: 14),
    elevation: 0,
    color: Theme.of(context).colorScheme.surfaceContainerLowest,
    shape: RoundedRectangleBorder(
      side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );
}
