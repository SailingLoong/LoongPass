import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'account_details.dart';
import 'account_workspace_registry.dart';
import 'compact_accounts_table.dart';
import 'desktop_theme.dart';
import 'managed_app.dart';
import 'magpie_usage.dart';
import 'workspace_usage.dart';
import 'plugin_rewards.dart';
import 'reward_batch_action.dart';
import 'ui_preferences.dart';
import 'workspace_expiry_week.dart';
import 'workspace_page.dart';

part 'workspace_overview.dart';
part 'workspace_expiry_calendar.dart';
part 'workspace_activity.dart';
part 'workspace_account_empty.dart';

class WorkspaceAccountsPage extends StatefulWidget {
  const WorkspaceAccountsPage({
    super.key,
    required this.registry,
    this.serviceStatus,
    this.onOpenApp,
  });
  final AccountWorkspaceRegistry registry;
  final Widget? serviceStatus;

  /// Starts the chosen platform's add-account flow after explicit selection.
  final ValueChanged<ManagedApp>? onOpenApp;
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
    builder: (context, _) {
      final entries = widget.registry.entries;
      return WorkspacePage(
        title: '账号与积分',
        action: widget.onOpenApp == null
            ? null
            : _AddAccount(onSelected: widget.onOpenApp!),
        children: [
          if (widget.serviceStatus != null) widget.serviceStatus!,
          if (entries.isNotEmpty)
            CompactAccountsTable(
              key: _table,
              entries: entries,
              registry: widget.registry,
            )
          else if (widget.serviceStatus == null)
            const _AccountEmpty(
              title: '暂无已保存账号',
              description: '选择平台并添加账号，开始管理你的账号与额度。',
              icon: Icon(FLucideIcons.wallet, size: 28),
            ),
        ],
      );
    },
  );
}

class _AddAccount extends StatelessWidget {
  const _AddAccount({required this.onSelected});
  final ValueChanged<ManagedApp> onSelected;
  @override
  Widget build(BuildContext context) => FButton(
    size: FButtonSizeVariant.sm,
    mainAxisSize: MainAxisSize.min,
    prefix: const Icon(FLucideIcons.plus, size: 16),
    onPress: () async {
      final platforms =
          UiPreferencesScope.maybeOf(context)?.appOrder ?? ManagedApp.values;
      final selected = await showFDialog<ManagedApp>(
        context: context,
        builder: (context, style, animation) => FDialog(
          animation: animation,
          constraints: const BoxConstraints(maxWidth: 440),
          builder: (context, style) => Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('选择平台', style: style.titleTextStyle),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final app in platforms)
                          FItem(
                            prefix: Image.asset(
                              app.iconAsset,
                              width: 24,
                              height: 24,
                            ),
                            title: Text(app.label),
                            subtitle: Text(app.region),
                            onPress: () => Navigator.pop(context, app),
                          ),
                      ],
                    ),
                  ),
                ),
                FButton(
                  variant: FButtonVariant.ghost,
                  onPress: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
              ],
            ),
          ),
        ),
      );
      if (selected != null && context.mounted) onSelected(selected);
    },
    child: const Text('添加账号'),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, this.count, {this.actionable = false});
  final String title;
  final int count;
  final bool actionable;
  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final palette = context.desktopPalette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            title,
            style: context.theme.typography.display.lg.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: actionable && count > 0
                  ? palette.warningSurface
                  : colors.muted,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              '$count',
              style: context.theme.typography.body.xs.copyWith(
                color: actionable && count > 0
                    ? palette.warning
                    : colors.mutedForeground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountLine extends StatelessWidget {
  const _AccountLine(
    this.account,
    this.registry, {
    this.status,
    this.amount,
    this.batchAt,
    this.receipt = false,
    this.showResolution = false,
  });
  final WorkspaceAccount account;
  final AccountWorkspaceRegistry registry;
  final String? status, amount;
  final DateTime? batchAt;
  final bool receipt, showResolution;

  @override
  Widget build(BuildContext context) {
    final entry = account.entry;
    final resolution = showResolution ? entry.resolution : null;
    final action = resolution == null
        ? null
        : FButton(
            variant: FButtonVariant.outline,
            size: FButtonSizeVariant.sm,
            mainAxisSize: MainAxisSize.min,
            onPress: resolution.run,
            child: Text(resolution.label),
          );
    final stateText = status ?? entry.statusLabel ?? entry.status;
    final muted = context.theme.typography.body.xs.copyWith(
      color: context.theme.colors.mutedForeground,
    );
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.theme.colors.border)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (context, box) {
          final wide =
              box.maxWidth >=
              380 * MediaQuery.textScalerOf(context).scale(14) / 14;
          final facts = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: wide
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              if (amount != null)
                Text(
                  amount!,
                  style: context.theme.typography.body.sm.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              Text(
                stateText,
                style: muted,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              if (batchAt != null &&
                  entry
                          .expiryModels[(at: batchAt!, amount: amount)]
                          ?.isNotEmpty ==
                      true)
                Text(
                  '查看可用模型',
                  style: muted.copyWith(color: context.desktopPalette.brand),
                ),
            ],
          );
          final item = FItem(
            prefix: Image.asset(account.app.iconAsset, width: 26, height: 26),
            title: Text(
              entry.label,
              style: context.theme.typography.body.sm.copyWith(
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: wide
                ? Text(account.app.label)
                : amount == null
                ? Text(
                    '${account.app.label} · $stateText',
                    style: muted,
                    maxLines: 3,
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [Text(account.app.label), facts],
                  ),
            details: wide
                ? ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: box.maxWidth * .38),
                    child: facts,
                  )
                : null,
            onPress: () => showAccountDetails(
              context,
              listenable: registry,
              app: account.app,
              read: () =>
                  registry.entries.where((e) => e.id == entry.id).firstOrNull,
              batch: batchAt == null ? null : (at: batchAt!, amount: amount),
              section: receipt
                  ? AccountDetailSection.receipt
                  : AccountDetailSection.summary,
            ),
            suffix: action == null
                ? const Icon(FLucideIcons.chevronRight, size: 15)
                : null,
          );
          if (action == null) return item;
          if (wide)
            return Row(
              children: [
                Expanded(child: item),
                action,
              ],
            );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              item,
              Align(alignment: Alignment.centerRight, child: action),
            ],
          );
        },
      ),
    );
  }
}
