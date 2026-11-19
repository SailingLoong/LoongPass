import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'account_workspace_registry.dart';
import 'compact_accounts_table.dart';
import 'managed_app.dart';
import 'workspace_tools.dart';
import 'account_details.dart';
import 'plugin_rewards.dart';
import 'reward_batch_action.dart';

class WorkspaceAccountsPage extends StatefulWidget {
  const WorkspaceAccountsPage({
    super.key,
    required this.registry,
    this.serviceStatus,
  });
  final AccountWorkspaceRegistry registry;
  final Widget? serviceStatus;
  @override
  State<WorkspaceAccountsPage> createState() => WorkspaceAccountsPageState();
}

class WorkspaceAccountsPageState extends State<WorkspaceAccountsPage> {
  final _table = GlobalKey<CompactAccountsTableState>();

  bool revealAccount(String id) =>
      _table.currentState?.revealAccount(id) ?? false;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.registry,
    builder: (context, _) => WorkspacePage(
      title: '账号与积分',
      subtitle: '${widget.registry.entries.length} 个账号',
      children: [
        if (widget.serviceStatus != null) widget.serviceStatus!,
        if (widget.serviceStatus == null || widget.registry.entries.isNotEmpty)
          CompactAccountsTable(key: _table, entries: widget.registry.entries),
      ],
    ),
  );
}

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
  final Widget? serviceStatus;
  final ValueChanged<ManagedApp> onOpenApp;
  final PluginRewards? rewards;
  final VoidCallback? onOpenRewards;
  @override
  State<WorkspaceOverviewPage> createState() => _WorkspaceOverviewPageState();
}

class _WorkspaceOverviewPageState extends State<WorkspaceOverviewPage> {
  bool _allAttention = false, _allExpiring = false;
  AccountWorkspaceRegistry get registry => widget.registry;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: registry,
    builder: (context, _) {
      final accounts = registry.accounts;
      final now = DateTime.now(),
          week = DateTime.now().add(const Duration(days: 7));
      final expiring =
          accounts
              .where(
                (a) =>
                    a.entry.nextExpiry != null &&
                    a.entry.nextExpiry!.isAfter(now) &&
                    !a.entry.nextExpiry!.isAfter(week),
              )
              .toList()
            ..sort(
              (a, b) => a.entry.nextExpiry!.compareTo(b.entry.nextExpiry!),
            );
      final attention = accounts.where((a) => a.entry.needsAttention).toList();
      final secondary = context.theme.typography.body.xs.copyWith(
        color: context.theme.colors.mutedForeground,
      );
      return WorkspacePage(
        title: '总览',
        subtitle: '',
        children: [
          if (widget.serviceStatus != null) widget.serviceStatus!,
          if (widget.rewards case final rewards?) ...[
            RewardBatchAction(
              rewards: rewards,
              onStarted: widget.onOpenRewards,
            ),
            const SizedBox(height: 16),
          ],
          Wrap(
            spacing: 32,
            runSpacing: 12,
            children: [
              for (final metric in [
                ('${accounts.length}', '已保存账号'),
                ('${attention.length}', '待处理'),
                ('${expiring.length}', '7 天内到期'),
              ])
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      metric.$1,
                      style: context.theme.typography.display.xl.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(metric.$2, style: secondary),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 20),
          if (attention.isNotEmpty)
            WorkspaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '需要处理',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  for (final account
                      in _allAttention ? attention : attention.take(5))
                    FItem(
                      title: Text(account.entry.label),
                      subtitle: Text(
                        '${account.app.label} · ${account.entry.statusLabel ?? account.entry.status}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      suffix: const Icon(FLucideIcons.chevronRight, size: 16),
                      onPress: () =>
                          _openAccount(context, registry, account.entry.id),
                    ),
                  if (attention.length > 5)
                    FButton(
                      key: const Key('overview-all-attention'),
                      variant: FButtonVariant.ghost,
                      size: FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: () =>
                          setState(() => _allAttention = !_allAttention),
                      child: Text(
                        _allAttention ? '收起' : '查看全部 ${attention.length} 个账号',
                      ),
                    ),
                ],
              ),
            ),
          WorkspaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '最近到期',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                if (expiring.isEmpty) Text('暂无已知的 7 天内到期额度', style: secondary),
                for (final account
                    in _allExpiring ? expiring : expiring.take(5))
                  FItem(
                    title: Text(account.entry.label),
                    subtitle: Text(
                      '${account.app.label} · ${account.entry.upcomingExpiryText}',
                    ),
                    suffix: const Icon(FLucideIcons.chevronRight, size: 16),
                    onPress: () => _openAccount(
                      context,
                      registry,
                      account.entry.id,
                      expiry: true,
                    ),
                  ),
                if (expiring.length > 5)
                  FButton(
                    key: const Key('overview-all-expiring'),
                    variant: FButtonVariant.ghost,
                    size: FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    onPress: () => setState(() => _allExpiring = !_allExpiring),
                    child: Text(
                      _allExpiring ? '收起' : '查看全部 ${expiring.length} 个账号',
                    ),
                  ),
              ],
            ),
          ),
          if (accounts.isEmpty && widget.serviceStatus == null)
            WorkspaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('从第一个账号开始', style: context.theme.typography.display.lg),
                  const SizedBox(height: 8),
                  const Text('选择平台，在官方窗口完成授权。账号与可用额度会显示在这里。'),
                  const SizedBox(height: 12),
                  FButton(
                    size: FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    onPress: () => widget.onOpenApp(ManagedApp.workbuddy),
                    child: const Text('添加账号'),
                  ),
                ],
              ),
            ),
        ],
      );
    },
  );
}

class WorkspaceActivityPage extends StatefulWidget {
  const WorkspaceActivityPage({
    super.key,
    required this.registry,
    this.rewards,
    this.serviceStatus,
  });
  final AccountWorkspaceRegistry registry;
  final PluginRewards? rewards;
  final Widget? serviceStatus;
  @override
  State<WorkspaceActivityPage> createState() => _WorkspaceActivityPageState();
}

enum _RewardView {
  accounts('签到账号'),
  receipts('最近成功领取'),
  attention('待处理');

  const _RewardView(this.label);
  final String label;
}

class _WorkspaceActivityPageState extends State<WorkspaceActivityPage> {
  _RewardView _view = _RewardView.accounts;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.registry,
    builder: (context, _) {
      final records = widget.registry.accounts
          .where(
            (a) => switch (_view) {
              _RewardView.accounts => a.entry.hasRewards,
              _RewardView.receipts => a.entry.receipt != null,
              _RewardView.attention =>
                a.entry.hasRewards && a.entry.needsAttention,
            },
          )
          .toList();
      if (_view == _RewardView.receipts)
        records.sort((a, b) {
          final x = a.entry.receipt!.confirmedAt,
              y = b.entry.receipt!.confirmedAt;
          return x == null
              ? (y == null ? 0 : 1)
              : y == null
              ? -1
              : y.compareTo(x);
        });
      return WorkspacePage(
        title: '辅助签到',
        subtitle: '',
        children: [
          if (widget.serviceStatus != null) widget.serviceStatus!,
          if (widget.rewards case final rewards?) ...[
            RewardBatchAction(rewards: rewards),
            const SizedBox(height: 16),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final view in _RewardView.values)
                FButton(
                  variant: _view == view
                      ? FButtonVariant.secondary
                      : FButtonVariant.ghost,
                  size: FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  child: Text(view.label),
                  selected: _view == view,
                  onPress: () => setState(() => _view = view),
                ),
            ],
          ),
          const SizedBox(height: 16),
          WorkspaceCard(
            child: records.isEmpty
                ? Text(switch (_view) {
                    _RewardView.accounts => '暂无支持辅助签到的已保存账号。',
                    _RewardView.receipts => '暂无已确认的领取记录。',
                    _RewardView.attention => '暂无待处理的领取记录。',
                  })
                : Column(
                    children: [
                      for (final account in records)
                        FItem(
                          title: Text(account.entry.label),
                          subtitle: Text(
                            '${account.app.label} · ${account.app.region} · ${_view == _RewardView.receipts ? account.entry.receipt!.display : account.entry.statusLabel ?? account.entry.status}',
                          ),
                          prefix: Icon(
                            _view == _RewardView.receipts
                                ? FLucideIcons.circleCheck
                                : FLucideIcons.info,
                            size: 16,
                            color: context.theme.colors.mutedForeground,
                          ),
                          suffix: const Icon(
                            FLucideIcons.chevronRight,
                            size: 16,
                          ),
                          onPress: () => _openAccount(
                            context,
                            widget.registry,
                            account.entry.id,
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      );
    },
  );
}

void _openAccount(
  BuildContext context,
  AccountWorkspaceRegistry registry,
  String id, {
  bool expiry = false,
}) => showAccountDetails(
  context,
  listenable: registry,
  read: () => registry.entries.where((e) => e.id == id).firstOrNull,
  expiry: expiry,
);
