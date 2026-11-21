part of 'workspace_accounts.dart';

class WorkspaceOverviewPage extends StatefulWidget {
  const WorkspaceOverviewPage({
    super.key,
    required this.registry,
    required this.onOpenApp,
    this.rewards,
    this.onOpenRewards,
    this.serviceStatus,
  });
  final AccountWorkspaceRegistry registry;

  /// Starts the chosen platform's add-account flow from the first-run prompt.
  final ValueChanged<ManagedApp> onOpenApp;
  final VoidCallback? onOpenRewards;
  final PluginRewards? rewards;
  final Widget? serviceStatus;
  @override
  State<WorkspaceOverviewPage> createState() => _WorkspaceOverviewPageState();
}

class _WorkspaceOverviewPageState extends State<WorkspaceOverviewPage> {
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.registry,
    builder: (context, _) {
      final registry = widget.registry;
      final accounts = registry.accounts;
      if (accounts.isEmpty) {
        return WorkspacePage(
          title: '总览',
          children: [
            widget.serviceStatus ?? _FirstAccountPrompt(widget.onOpenApp),
          ],
        );
      }
      Widget attention(AccountAttention kind) => _AttentionList(
        key: ValueKey(kind),
        registry: registry,
        kind: kind,
        records: accounts.where((a) => a.entry.attention == kind).toList(),
      );
      return WorkspacePage(
        title: '总览',
        action: widget.rewards == null
            ? null
            : RewardBatchAction(
                rewards: widget.rewards!,
                onStarted: widget.onOpenRewards,
              ),
        children: [
          if (widget.serviceStatus != null) widget.serviceStatus!,
          if (widget.rewards != null)
            RewardBatchStatus(rewards: widget.rewards!),
          attention(AccountAttention.actionRequired),
          const SizedBox(height: 26),
          _ExpiryCalendar(accounts: accounts, registry: registry),
          if (accounts.any(
            (a) => a.entry.attention == AccountAttention.awaitingVerification,
          )) ...[
            const SizedBox(height: 22),
            attention(AccountAttention.awaitingVerification),
          ],
        ],
      );
    },
  );
}

class _AttentionList extends StatefulWidget {
  const _AttentionList({
    super.key,
    required this.records,
    required this.registry,
    required this.kind,
  });
  final List<WorkspaceAccount> records;
  final AccountWorkspaceRegistry registry;
  final AccountAttention kind;
  @override
  State<_AttentionList> createState() => _AttentionListState();
}

class _AttentionListState extends State<_AttentionList> {
  bool expanded = false;
  @override
  Widget build(BuildContext context) {
    final actionable = widget.kind == AccountAttention.actionRequired;
    final records = widget.records;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          actionable ? '需要你处理' : '待核验',
          records.length,
          actionable: actionable,
        ),
        if (actionable && records.isNotEmpty)
          Container(height: 1, color: context.theme.colors.border),
        if (records.isEmpty)
          Text(
            actionable ? '没有需要你操作的账号。' : '暂无待核验项目。',
            style: context.theme.typography.body.sm.copyWith(
              color: context.theme.colors.mutedForeground,
            ),
          ),
        for (final a in expanded ? records : records.take(3))
          _AccountLine(a, widget.registry, showResolution: true),
        if (records.length > 3)
          FButton(
            key: Key(
              actionable ? 'overview-all-attention' : 'overview-all-pending',
            ),
            variant: FButtonVariant.ghost,
            size: FButtonSizeVariant.sm,
            mainAxisSize: MainAxisSize.min,
            onPress: () => setState(() => expanded = !expanded),
            child: Text(expanded ? '收起' : '查看全部 ${records.length} 个账号'),
          ),
      ],
    );
  }
}
