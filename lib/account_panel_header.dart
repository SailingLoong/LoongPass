import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'account_workspace_registry.dart';
import 'workspace_page.dart';

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
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: WorkspaceHeading(
        title: title,
        subtitle: [
          if (app != null) app.region,
          '$accountCount 个账号',
        ].join(' · '),
        action: Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ...actions,
            AccountPanelHelp(text: helpText),
          ],
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
