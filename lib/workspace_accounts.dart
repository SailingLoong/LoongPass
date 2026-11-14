import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'account_workspace_registry.dart';
import 'compact_accounts_table.dart';
import 'managed_app.dart';
import 'workspace_tools.dart';
import 'account_details.dart';

class WorkspaceAccountsPage extends StatelessWidget {
  const WorkspaceAccountsPage({
    super.key,
    required this.registry,
    this.serviceStatus,
  });
  final AccountWorkspaceRegistry registry;
  final Widget? serviceStatus;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: registry,
    builder: (context, _) => WorkspacePage(
      title: '账号与积分',
      subtitle: '${registry.entries.length} 个账号',
      children: [
        if (serviceStatus != null) serviceStatus!,
        if (serviceStatus == null || registry.entries.isNotEmpty)
          CompactAccountsTable(entries: registry.entries),
      ],
    ),
  );
}

class WorkspaceOverviewPage extends StatefulWidget {
  const WorkspaceOverviewPage({
    super.key,
    required this.registry,
    required this.onOpenApp,
    this.serviceStatus,
  });
  final AccountWorkspaceRegistry registry;
  final Widget? serviceStatus;
  final ValueChanged<ManagedApp> onOpenApp;
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
          Wrap(
            spacing: 32,
            runSpacing: 12,
            children: [
              for (final metric in [
                ('${accounts.length}', '已保存账号'),
                ('${attention.length}', '待处理'),
                ('${expiring.length}', '7 天内到期'),
                if (accounts.any((a) => a.entry.automatic != null))
                  (
                    '${accounts.where((a) => a.entry.automatic == true).length}',
                    '自动领取已开启',
                  ),
              ])
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      metric.$1,
                      style: context.theme.typography.body.lg.copyWith(
                        fontSize: 20,
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
    this.serviceStatus,
  });
  final AccountWorkspaceRegistry registry;
  final Widget? serviceStatus;
  @override
  State<WorkspaceActivityPage> createState() => _WorkspaceActivityPageState();
}

class _WorkspaceActivityPageState extends State<WorkspaceActivityPage> {
  bool _attention = false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.registry,
    builder: (context, _) {
      final records = widget.registry.accounts
          .where(
            (a) =>
                _attention ? a.entry.needsAttention : a.entry.receipt != null,
          )
          .toList();
      if (!_attention)
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
        title: '最近领取',
        subtitle: '各账号最近一次已确认的领取记录',
        children: [
          if (widget.serviceStatus != null) widget.serviceStatus!,
          Wrap(
            spacing: 8,
            children: [
              FButton(
                variant: !_attention
                    ? FButtonVariant.secondary
                    : FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                child: const Text('最近成功领取'),
                selected: !_attention,
                onPress: () => setState(() => _attention = false),
              ),
              FButton(
                variant: _attention
                    ? FButtonVariant.secondary
                    : FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                child: const Text('待处理'),
                selected: _attention,
                onPress: () => setState(() => _attention = true),
              ),
            ],
          ),
          const SizedBox(height: 16),
          WorkspaceCard(
            child: records.isEmpty
                ? const Text('暂无对应记录。尚未确认的领取不会显示为成功。')
                : Column(
                    children: [
                      for (final account in records)
                        FItem(
                          title: Text(account.entry.label),
                          subtitle: Text(
                            '${account.app.label} · ${_attention ? account.entry.statusLabel ?? account.entry.status : account.entry.receipt!.display}',
                          ),
                          prefix: Icon(
                            _attention
                                ? FLucideIcons.info
                                : FLucideIcons.circleCheck,
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
