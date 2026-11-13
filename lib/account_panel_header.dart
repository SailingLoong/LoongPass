import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'account_workspace_registry.dart';

class AccountPanelToolbar extends StatelessWidget {
  const AccountPanelToolbar({
    super.key,
    required this.title,
    required this.accountCount,
    required this.helpText,
    required this.actions,
  });
  final String title, helpText;
  final int accountCount;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) {
    final app = AccountPresentationScope.maybeOf(context)?.app;
    final colors = context.theme.colors;
    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: context.theme.typography.display.xl),
        const SizedBox(height: 5),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (app != null) Text(app.region),
            Text('$accountCount 个账号'),
          ],
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DefaultTextStyle.merge(
        style: context.theme.typography.body.xs.copyWith(
          color: colors.mutedForeground,
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final wide = box.maxWidth >= 520 * scale;
            final controls = Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: wide ? WrapAlignment.end : WrapAlignment.start,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ...actions,
                AccountPanelHelp(text: helpText),
              ],
            );
            return wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: identity),
                      const SizedBox(width: 16),
                      Flexible(flex: 2, child: controls),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [identity, const SizedBox(height: 12), controls],
                  );
          },
        ),
      ),
    );
  }
}

class AccountPanelHelp extends StatelessWidget {
  const AccountPanelHelp({super.key, required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => FTooltip(
    tipBuilder: (context, controller) => Text('使用说明'),
    child: Semantics(
      tooltip: '使用说明',
      child: FButton.icon(
        variant: FButtonVariant.ghost,
        size: FButtonSizeVariant.sm,
        onPress: () => showFDialog<void>(
          context: context,
          builder: (context, style, animation) => FDialog(
            animation: animation,
            constraints: const BoxConstraints(minWidth: 280, maxWidth: 640),
            builder: (context, style) => Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DefaultTextStyle(
                    style: style.titleTextStyle,
                    child: const Text('账号与领取说明'),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: DefaultTextStyle(
                      style: style.bodyTextStyle,
                      child: SizedBox(
                        width: 500,
                        child: SingleChildScrollView(child: Text(text)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    children: [
                      FButton(
                        variant: FButtonVariant.ghost,
                        size: FButtonSizeVariant.sm,
                        mainAxisSize: MainAxisSize.min,
                        child: const Text('关闭'),
                        onPress: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        child: const Icon(FLucideIcons.circleHelp, size: 16),
      ),
    ),
  );
}
