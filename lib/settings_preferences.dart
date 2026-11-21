import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;

import 'app_order_item.dart';
import 'invitation_settings.dart';
import 'invitation_settings_panel.dart';
import 'managed_app.dart';
import 'ui_preferences.dart';

class SettingsOption extends StatelessWidget {
  const SettingsOption({
    super.key,
    required this.title,
    this.description,
    required this.control,
  });
  final String title;
  final String? description;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final label = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: theme.typography.body.sm.copyWith(fontWeight: FontWeight.w600),
        ),
        if (description != null) const SizedBox(height: 4),
        if (description != null)
          Text(
            description!,
            style: theme.typography.body.xs.copyWith(
              color: theme.colors.mutedForeground,
              height: 1.5,
            ),
          ),
      ],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.colors.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: LayoutBuilder(
          builder: (context, box) {
            if (box.maxWidth <
                460 * MediaQuery.textScalerOf(context).scale(14) / 14) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [label, const SizedBox(height: 8), control],
              );
            }
            return Row(
              children: [
                Expanded(child: label),
                const SizedBox(width: 16),
                Flexible(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: control,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Choice<T> extends StatelessWidget {
  const _Choice({
    super.key,
    required this.value,
    required this.options,
    required this.onChange,
  });
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChange;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: context.theme.colors.muted,
      borderRadius: context.theme.style.borderRadius.md,
    ),
    child: Padding(
      padding: const EdgeInsets.all(3),
      child: Wrap(
        spacing: 2,
        runSpacing: 2,
        children: [
          for (final option in options.entries)
            Semantics(
              selected: option.key == value,
              inMutuallyExclusiveGroup: true,
              child: FButton(
                mainAxisSize: MainAxisSize.min,
                size: FButtonSizeVariant.sm,
                variant: option.key == value
                    ? FButtonVariant.outline
                    : FButtonVariant.ghost,
                onPress: () => onChange(option.key),
                child: Text(option.value),
              ),
            ),
        ],
      ),
    ),
  );
}

class SettingsAppearance extends StatelessWidget {
  const SettingsAppearance({super.key, required this.preferences});
  final UiPreferences preferences;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SettingsOption(
        title: '主题',
        control: _Choice(
          key: const Key('appearance-theme'),
          value: preferences.themeMode,
          options: const {
            ThemeMode.system: '跟随系统',
            ThemeMode.light: '浅色',
            ThemeMode.dark: '深色',
          },
          onChange: preferences.setTheme,
        ),
      ),
      SettingsOption(
        title: '账号行距',
        control: _Choice(
          key: const Key('account-row-density'),
          value: preferences.comfortable,
          options: const {false: '紧凑', true: '舒适'},
          onChange: preferences.setComfortable,
        ),
      ),
    ],
  );
}

class SettingsPlatforms extends StatelessWidget {
  const SettingsPlatforms({
    super.key,
    required this.preferences,
    required this.invitations,
    required this.draftFor,
  });
  final UiPreferences preferences;
  final Map<ManagedApp, InvitationSettings> invitations;
  final TextEditingController Function(InvitationSettings) draftFor;

  Future<void> _edit(
    BuildContext context,
    ManagedApp app,
    InvitationSettings settings,
  ) => showFDialog<void>(
    context: context,
    builder: (context, style, animation) => FDialog(
      animation: animation,
      constraints: const BoxConstraints(maxWidth: 448),
      builder: (context, style) => SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${app.label} 邀请设置',
              style: context.theme.typography.display.xl.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            InvitationSettingsPanel(
              key: ValueKey(app),
              settings: settings,
              controller: draftFor(settings),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FButton(
                size: FButtonSizeVariant.sm,
                variant: FButtonVariant.outline,
                mainAxisSize: MainAxisSize.min,
                onPress: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final titleStyle = context.theme.typography.display.lg.copyWith(
      fontWeight: FontWeight.w600,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '平台顺序',
              key: const Key('platform-order-settings'),
              style: titleStyle,
            ),
            FButton(
              size: FButtonSizeVariant.sm,
              variant: FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: preferences.resetOrder,
              child: const Text('恢复默认应用顺序'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '拖动整行或使用箭头排序；开关控制侧栏是否显示。',
          style: context.theme.typography.body.xs.copyWith(
            color: context.theme.colors.mutedForeground,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 8),
        ReorderableList(
          key: const Key('app-order'),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: preferences.appOrder.length,
          onReorderItem: preferences.reorder,
          proxyDecorator: (child, index, animation) => MouseRegion(
            cursor: SystemMouseCursors.grabbing,
            child: ColoredBox(color: context.theme.colors.muted, child: child),
          ),
          itemBuilder: (context, index) {
            final app = preferences.appOrder[index];
            return AppOrderItem(
              key: ValueKey('ordered-${app.name}'),
              app: app,
              index: index,
              canMoveUp: index > 0,
              canMoveDown: index + 1 < preferences.appOrder.length,
              visible: preferences.isAppVisible(app),
              onShow: (show) => preferences.setAppVisible(app, show),
              onMove: (delta) => preferences.reorder(index, index + delta),
            );
          },
        ),
        if (invitations.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('邀请设置', style: titleStyle),
          for (final entry in invitations.entries)
            SettingsOption(
              title: entry.key.label,
              control: FButton(
                key: ValueKey('invitation-${entry.key.name}'),
                size: FButtonSizeVariant.sm,
                variant: FButtonVariant.outline,
                mainAxisSize: MainAxisSize.min,
                semanticsLabel: '编辑 ${entry.key.label} 邀请设置',
                onPress: () => _edit(context, entry.key, entry.value),
                child: const Text('编辑'),
              ),
            ),
        ],
      ],
    );
  }
}
