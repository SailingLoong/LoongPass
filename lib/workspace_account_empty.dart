part of 'workspace_accounts.dart';

class _AccountEmpty extends StatelessWidget {
  const _AccountEmpty({
    required this.title,
    required this.icon,
    this.description,
    this.action,
  });
  final Widget icon;
  final String title;
  final String? description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final firstRun = action != null;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: 20,
        vertical: firstRun
            ? (MediaQuery.sizeOf(context).width * .06).clamp(24.0, 80.0)
            : 32,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: context.desktopPalette.sidebar,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(
            child: IconTheme(
              data: IconThemeData(color: colors.mutedForeground),
              child: icon,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style:
                (firstRun
                        ? context.theme.typography.display.xl
                        : context.theme.typography.body.md)
                    .copyWith(fontWeight: FontWeight.w600),
          ),
          if (description != null) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Text(
                description!,
                textAlign: TextAlign.center,
                style: context.theme.typography.body.sm.copyWith(
                  color: colors.mutedForeground,
                ),
              ),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}

class _FirstAccountPrompt extends StatelessWidget {
  const _FirstAccountPrompt(this.onSelected);
  final ValueChanged<ManagedApp> onSelected;
  @override
  Widget build(BuildContext context) => _AccountEmpty(
    title: '从第一个账号开始',
    description: '选择平台，在官方窗口完成授权。之后就能在这里看到需要处理的账号和快到期的额度。',
    icon: Wrap(
      alignment: WrapAlignment.center,
      spacing: 10,
      children: [
        for (final app in [
          ManagedApp.codex,
          ManagedApp.workbuddy,
          ManagedApp.minimaxCn,
        ])
          Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: context.theme.colors.background,
              border: Border.all(color: context.theme.colors.border),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Image.asset(app.iconAsset, width: 30, height: 30),
          ),
      ],
    ),
    action: _AddAccount(onSelected: onSelected),
  );
}
