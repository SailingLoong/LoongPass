part of 'workspace_accounts.dart';

class _AccountEmpty extends StatelessWidget {
  const _AccountEmpty({
    required this.title,
    required this.icon,
    this.description,
  });
  final Widget icon;
  final String title;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
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
            style: context.theme.typography.body.md.copyWith(
              fontWeight: FontWeight.w600,
            ),
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
        ],
      ),
    );
  }
}

class _ApplicationTiles extends StatelessWidget {
  const _ApplicationTiles({
    required this.registry,
    required this.onLogin,
    required this.onManage,
  });
  final AccountWorkspaceRegistry registry;
  final ValueChanged<ManagedApp> onLogin;
  final ValueChanged<ManagedApp>? onManage;

  @override
  Widget build(BuildContext context) {
    final apps =
        UiPreferencesScope.maybeOf(context)?.appOrder ?? ManagedApp.values;
    final hasAccounts = registry.accounts.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: LayoutBuilder(
        builder: (context, box) {
          final columns = box.maxWidth >= 810
              ? 3
              : box.maxWidth >= 450
              ? 2
              : 1;
          return Wrap(
            spacing: 12,
            runSpacing: 10,
            children: [
              for (final app in apps)
                if (!hasAccounts || registry.entriesFor(app).isNotEmpty)
                  SizedBox(
                    width: (box.maxWidth - 12 * (columns - 1)) / columns,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: context.theme.colors.border),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: FItem(
                        key: ValueKey('home-app-${app.name}'),
                        prefix: Image.asset(
                          app.iconAsset,
                          width: 32,
                          height: 32,
                          excludeFromSemantics: true,
                        ),
                        title: Text(app.label),
                        subtitle: Text(
                          registry.entriesFor(app).isEmpty
                              ? '${app.region} · 注册或登录'
                              : '${app.region} · ${registry.entriesFor(app).length} 个账号',
                        ),
                        suffix: const Icon(FLucideIcons.chevronRight, size: 16),
                        onPress: () => registry.entriesFor(app).isEmpty
                            ? onLogin(app)
                            : (onManage ?? onLogin)(app),
                      ),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}
