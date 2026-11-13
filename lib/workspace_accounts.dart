import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'account_workspace_registry.dart';
import 'compact_accounts_table.dart';
import 'managed_app.dart';
import 'workspace_tools.dart';
import 'account_details.dart';

class WorkspaceAccountsPage extends StatelessWidget {
  const WorkspaceAccountsPage({super.key, required this.registry});
  final AccountWorkspaceRegistry registry;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: registry,
    builder: (context, _) => WorkspacePage(
      title: '账号与积分',
      subtitle: '按平台查找账号，余额与到期信息分别展示。',
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
        subtitle: '先处理需要关注的账号，再查看近期到期额度。',
        children: [
          Wrap(
            spacing: 20,
            runSpacing: 8,
            children: [
              Text('${accounts.length} 个已保存账号'),
              Text('${attention.length} 个待处理'),
              Text('${expiring.length} 个近期到期'),
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
                  for (final account in attention.take(5))
                    FItem(
                      title: Text(
                        '${account.app.label} · ${account.entry.label}',
                      ),
                      subtitle: Text(account.entry.status),
                      suffix: const Icon(FLucideIcons.chevronRight, size: 18),
                      onPress: () =>
                          _openAccount(context, registry, account.entry.id),
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
                if (expiring.isEmpty)
                  const Text('暂无已知的 7 天内到期额度。未提供到期明细的账号仍需单独核对。'),
                for (final account in expiring.take(5))
                  FItem(
                    title: Text(
                      '${account.app.label} · ${account.entry.label}',
                    ),
                    subtitle: Text(account.entry.upcomingExpiryText),
                    suffix: const Icon(FLucideIcons.chevronRight, size: 18),
                    onPress: () => _openAccount(
                      context,
                      registry,
                      account.entry.id,
                      expiry: true,
                    ),
                  ),
              ],
            ),
          ),
          if (accounts.isEmpty)
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
                    onPress: () => onOpenApp(ManagedApp.workbuddy),
                    child: const Text('添加账号'),
                  ),
                ],
              ),
            ),
          Text(
            '自动领取仅在 LoongPass 运行期间执行；各账号的开关与最近结果可在详情中查看。',
            style: context.theme.typography.body.xs.copyWith(
              color: context.theme.colors.mutedForeground,
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
        title: '最近领取',
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
