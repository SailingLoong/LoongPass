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
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          if (app != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                app.region,
                style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant),
              ),
            ),
          Text(
            '$accountCount 个账号',
            style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
          ),
          ...actions,
          AccountPanelHelp(text: helpText),
        ],
      ),
    );
  }
}

class AccountPanelHelp extends StatelessWidget {
  const AccountPanelHelp({super.key, required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => TextButton.icon(
    icon: const Icon(Icons.help_outline, size: 14),
    label: const Text('使用说明'),
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
