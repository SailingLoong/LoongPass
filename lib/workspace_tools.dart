import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'app_updates.dart';
import 'operation_log.dart';
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
  String? _logError;
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

  void _selectTopic(SettingsSection topic) {
    OperationLog.current?.record('navigation.settings', target: topic.name);
    section.value = topic;
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
        DecoratedBox(
          decoration: BoxDecoration(
            color: context.desktopPalette.sidebar,
            borderRadius: context.theme.style.borderRadius.md,
          ),
          child: const Padding(
            padding: EdgeInsets.all(16),
            child: Text('授权以明文保存在本机应用私有目录。界面偏好单独保存。'),
          ),
        ),
        SettingsOption(
          title: '辅助签到',
          description: '由你点击发起；进入页面不会触发领取。',
          control: _link('查看签到账号', widget.onOpenRewards),
        ),
        if (OperationLog.current != null)
          SettingsOption(
            title: '诊断日志',
            description: _logError ?? '仅在本机保留最近 7 天的记录。',
            control: _link('打开日志文件夹', () async {
              final opened = await OperationLog.current!.openFolder();
              if (mounted)
                setState(() => _logError = opened ? null : '无法打开日志文件夹。');
            }),
          ),
        SettingsOption(
          title: '账号服务',
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
                              onPress: () => _selectTopic(topic),
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
                    _selectTopic(SettingsSection.values[index]),
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
