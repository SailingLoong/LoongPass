import 'package:flutter/material.dart';
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
    final colors = Theme.of(context).colorScheme;
    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
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
      padding: const EdgeInsets.only(bottom: 18),
      child: DefaultTextStyle.merge(
        style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
        child: LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth >= 640;
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
                      Expanded(flex: 2, child: identity),
                      const SizedBox(width: 16),
                      Expanded(flex: 3, child: controls),
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
  Widget build(BuildContext context) => IconButton(
    icon: const Icon(Icons.help_outline, size: 16),
    tooltip: '使用说明',
    onPressed: () => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('账号与领取说明'),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(child: Text(text)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    ),
  );
}
