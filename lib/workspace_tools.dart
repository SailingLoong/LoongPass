import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'app_updates.dart';
import 'desktop_theme.dart';
import 'invitation_settings.dart';
import 'managed_app.dart';
import 'settings_preferences.dart';
import 'ui_preferences.dart';
import 'workspace_page.dart';

export 'workspace_page.dart';

enum SettingsSection {
  appearance('外观与列表'),
  platforms('平台与邀请'),
  updates('应用更新'),
  data('运行与数据');

  const SettingsSection(this.label);
  final String label;
}

class WorkspaceSettingsPage extends StatefulWidget {
  const WorkspaceSettingsPage({
    super.key,
    required this.preferences,
    this.updates,
    this.invitations = const {},
    this.section,
    this.onOpenAccounts,
    this.onOpenRewards,
  });
  final UiPreferences preferences;
  final AppUpdates? updates;
  final Map<ManagedApp, InvitationSettings> invitations;
  final ValueNotifier<SettingsSection>? section;
  final VoidCallback? onOpenAccounts, onOpenRewards;
  @override
  State<WorkspaceSettingsPage> createState() => _WorkspaceSettingsPageState();
}

class _WorkspaceSettingsPageState extends State<WorkspaceSettingsPage> {
  final _localSection = ValueNotifier(SettingsSection.appearance);
  final _drafts = <ManagedApp, TextEditingController>{};
  ValueNotifier<SettingsSection> get section => widget.section ?? _localSection;

  @override
  void dispose() {
    _localSection.dispose();
    for (final draft in _drafts.values) {
      draft.dispose();
    }
    super.dispose();
  }

  Widget _content(SettingsSection topic) => switch (topic) {
    SettingsSection.appearance => SettingsAppearance(
      preferences: widget.preferences,
    ),
    SettingsSection.platforms => SettingsPlatforms(
      preferences: widget.preferences,
      invitations: widget.invitations,
      draftFor: (settings) => _drafts.putIfAbsent(
        settings.app,
        () => TextEditingController(text: settings.overrideCode),
      ),
    ),
    SettingsSection.updates =>
      widget.updates == null
          ? const Text('当前平台不支持应用内更新。')
          : AppUpdateCard(updates: widget.updates!),
    SettingsSection.data => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '本机数据',
          style: context.theme.typography.display.lg.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        DecoratedBox(
          decoration: BoxDecoration(
            color: context.desktopPalette.sidebar,
            borderRadius: context.theme.style.borderRadius.md,
          ),
          child: const Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '授权资料保存在本机',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 6),
                Text('授权以明文保存在本机应用私有目录。界面偏好单独保存。'),
              ],
            ),
          ),
        ),
        SettingsOption(
          title: '辅助签到',
          description: '由你点击发起；进入页面不会触发领取。',
          control: _link('查看签到账号', widget.onOpenRewards),
        ),
        SettingsOption(
          title: '账号服务',
          description: '账号与额度由各平台提供。',
          control: _link('查看账号', widget.onOpenAccounts),
        ),
      ],
    ),
  };

  Widget _link(String label, VoidCallback? callback) => callback == null
      ? const SizedBox.shrink()
      : FButton(
          size: FButtonSizeVariant.sm,
          variant: FButtonVariant.outline,
          mainAxisSize: MainAxisSize.min,
          onPress: callback,
          child: Text(label),
        );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.preferences, section]),
    builder: (context, _) => WorkspacePage(
      title: '设置',
      subtitle: '管理外观、平台偏好和本机应用。',
      children: [
        if (widget.preferences.error case final error?) ...[
          Text(error),
          Align(
            alignment: Alignment.centerLeft,
            child: _link('重新保存界面偏好', widget.preferences.retrySave),
          ),
        ],
        LayoutBuilder(
          builder: (context, box) {
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            if (box.maxWidth < 350 * scale) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final topic in SettingsSection.values)
                        Semantics(
                          selected: topic == section.value,
                          inMutuallyExclusiveGroup: true,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  width: 2,
                                  color: topic == section.value
                                      ? context.desktopPalette.brand
                                      : const Color(0x00000000),
                                ),
                              ),
                            ),
                            child: FButton(
                              variant: FButtonVariant.ghost,
                              size: FButtonSizeVariant.sm,
                              mainAxisSize: MainAxisSize.min,
                              onPress: () => section.value = topic,
                              child: Text(topic.label, key: ValueKey(topic)),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  _content(section.value),
                ],
              );
            }
            return FTabs(
              scrollable: true,
              style: context.desktopTabStyle,
              control: FTabControl.lifted(
                index: section.value.index,
                onChange: (index) =>
                    section.value = SettingsSection.values[index],
              ),
              children: [
                for (final topic in SettingsSection.values)
                  FTabEntry(
                    label: Text(topic.label, key: ValueKey(topic)),
                    child: DefaultTextStyle(
                      style: context.theme.typography.body.sm,
                      child: _content(topic),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    ),
  );
}
