import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'account_workspace_registry.dart';
import 'compact_accounts_table.dart';
import 'managed_app.dart';
import 'workspace_tools.dart';

class WorkspaceAccountsPage extends StatelessWidget {
  const WorkspaceAccountsPage({super.key, required this.registry});
  final AccountWorkspaceRegistry registry;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: registry,
    builder: (context, _) => WorkspacePage(
      title: '账号与积分',
      subtitle: '已载入的各平台账号；不同平台与地区的余额分别列示。',
      children: [CompactAccountsTable(entries: registry.entries)],
    ),
  );
}

class WorkspaceOverviewPage extends StatelessWidget {
  const WorkspaceOverviewPage({
    super.key,
    required this.registry,
    required this.onOpenApp,
    required this.onOpenModels,
  });
  final AccountWorkspaceRegistry registry;
  final ValueChanged<ManagedApp> onOpenApp;
  final VoidCallback onOpenModels;
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
      return WorkspacePage(
        title: '总览',
        subtitle: '优先关注即将到期的积分和需要处理的账号。',
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _SummaryValue('已载入账号', accounts.length),
              _SummaryValue('7 天内到期', expiring.length),
              _SummaryValue('待处理', attention.length),
            ],
          ),
          const SizedBox(height: 20),
          WorkspaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '最近到期',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                if (expiring.isEmpty)
                  const Text('已载入的记录中暂无 7 天内到期信息。缺失明细的账号不代表永久有效。'),
                for (final account in expiring.take(5))
                  FItem(
                    title: Text(
                      '${account.app.label} · ${account.entry.label}',
                    ),
                    subtitle: Text(account.entry.upcomingExpiryText),
                    suffix: const Icon(FLucideIcons.chevronRight, size: 18),
                    onPress: () => onOpenApp(account.app),
                  ),
              ],
            ),
          ),
          if (attention.isNotEmpty)
            WorkspaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '需要处理',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  for (final account in attention.take(5))
                    FItem(
                      title: Text(
                        '${account.app.label} · ${account.entry.label}',
                      ),
                      subtitle: Text(account.entry.status),
                      suffix: const Icon(FLucideIcons.chevronRight, size: 18),
                      onPress: () => onOpenApp(account.app),
                    ),
                ],
              ),
            ),
          WorkspaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '我的应用',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final app in ManagedApp.values)
                      FButton(
                        variant: FButtonVariant.outline,
                        size: FButtonSizeVariant.sm,
                        mainAxisSize: MainAxisSize.min,
                        child: Text(
                          '${app.label} · ${registry.entriesFor(app).length} 个已载入',
                        ),
                        onPress: () => onOpenApp(app),
                      ),
                  ],
                ),
              ],
            ),
          ),
          WorkspaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '模型服务',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                const Text('在模型服务中查看本机连接设置和可用来源。'),
                FButton(
                  variant: FButtonVariant.ghost,
                  size: FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  child: const Text('查看模型服务'),
                  onPress: onOpenModels,
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
    required this.onOpenApp,
  });
  final AccountWorkspaceRegistry registry;
  final ValueChanged<ManagedApp> onOpenApp;
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
        title: '活动记录',
        subtitle: '展示各账号最近一次已确认领取，以及当前待处理状态；不是完整历史流水。',
        children: [
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
                          title: Text(
                            '${account.app.label} · ${account.entry.label}',
                          ),
                          subtitle: Text(
                            _attention
                                ? account.entry.status
                                : account.entry.receipt!.display,
                          ),
                          prefix: Icon(
                            _attention
                                ? FLucideIcons.info
                                : FLucideIcons.circleCheck,
                            size: 20,
                          ),
                          suffix: const Icon(
                            FLucideIcons.chevronRight,
                            size: 18,
                          ),
                          onPress: () => widget.onOpenApp(account.app),
                        ),
                    ],
                  ),
          ),
        ],
      );
    },
  );
}

class _SummaryValue extends StatelessWidget {
  const _SummaryValue(this.label, this.value);
  final String label;
  final int value;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 155,
    child: WorkspaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: context.theme.typography.body.sm.copyWith(
              color: context.theme.colors.mutedForeground,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$value',
            style: context.theme.typography.display.xl2.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );
}
