import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart' show SelectableText;

import 'account_table_entry.dart';
import 'credit_summary_view.dart';
import 'desktop_theme.dart';
import 'ui_preferences.dart';

/// All entry points observe the same live presentation; opening never refreshes.
Future<void> showAccountDetails(
  BuildContext context, {
  required Listenable listenable,
  required AccountTableEntry? Function() read,
  bool expiry = false,
  String? platform,
  String? preferenceId,
}) async {
  read()?.onOpenDetails?.call();
  final preferences = UiPreferencesScope.maybeOf(context);
  await showFSheet<void>(
    context: context,
    side: FLayout.rtl,
    draggable: false,
    mainAxisMaxRatio: 1,
    constraints: const BoxConstraints(maxWidth: 462),
    builder: (context) => ListenableBuilder(
      listenable: Listenable.merge([listenable, preferences]),
      builder: (context, _) {
        final row = read();
        final source = row?.sourceLabel ?? platform;
        final favoriteId = row?.preferenceId ?? preferenceId;
        return Container(
          key: const Key('account-detail-sheet'),
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            color: context.theme.colors.background,
            border: Border(
              left: BorderSide(color: context.theme.colors.border),
            ),
          ),

          child: Padding(
            padding: const EdgeInsets.fromLTRB(23, 20, 23, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '账号详情',
                        style: context.theme.typography.body.sm.copyWith(
                          color: context.theme.colors.mutedForeground,
                        ),
                      ),
                    ),
                    FButton(
                      variant: FButtonVariant.ghost,
                      size: FButtonSizeVariant.sm,
                      prefix: const Icon(FLucideIcons.x, size: 16),
                      onPress: () => Navigator.pop(context),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          row?.label ?? '账号已移除',
                          style: context.theme.typography.display.xl2.copyWith(
                            height: 1.4,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (source != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(source),
                          ),
                        if (row == null)
                          const Text('该账号已不在当前列表中。')
                        else ...[
                          if (row.notice != null) Text(row.notice!),
                          const SizedBox(height: 16),
                          if (row.hasCredits)
                            FTabs(
                              style: context.desktopTabStyle,
                              control: FTabControl.managed(
                                initial: expiry ? 1 : 0,
                              ),
                              scrollable: true,
                              children: [
                                FTabEntry(
                                  label: const Text('账号信息'),
                                  child: _AccountInfo(
                                    row: row,
                                    platform: source,
                                  ),
                                ),
                                FTabEntry(
                                  label: const Text('额度到期'),
                                  child: _ExpiryDetails(row: row),
                                ),
                              ],
                            )
                          else
                            _AccountInfo(row: row, platform: source),
                          if (row.actions != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 18),
                              child: row.actions,
                            ),
                          if (preferences != null && favoriteId != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: FButton(
                                  variant: FButtonVariant.outline,
                                  size: FButtonSizeVariant.sm,
                                  mainAxisSize: MainAxisSize.min,
                                  prefix: const Icon(
                                    FLucideIcons.star,
                                    size: 15,
                                  ),
                                  onPress: () =>
                                      preferences.toggleFavorite(favoriteId),
                                  child: Text(
                                    preferences.isFavorite(favoriteId)
                                        ? '已收藏'
                                        : '收藏账号',
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _AccountInfo extends StatelessWidget {
  const _AccountInfo({required this.row, this.platform});
  final String? platform;
  final AccountTableEntry row;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _AccountFact('平台', row.detailPlatform ?? platform ?? '未知'),
      _AccountFact(
        '账号 ID',
        row.officialId ?? '未提供',
        selectable: row.officialId != null,
      ),
      _AccountFact('授权状态', row.authorizationLabel ?? '未知'),
      if (row.hasCredits) _BalanceFacts(row),
      const SizedBox(height: 16),
      row.details,
      if (row.hasRewards) ...[
        const FDivider(),
        Text(
          '最近一次成功领取',
          style: context.theme.typography.body.sm.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(row.latestClaim),
      ],
    ],
  );
}

class _AccountFact extends StatelessWidget {
  const _AccountFact(this.name, this.value, {this.selectable = false});
  final String name, value;
  final bool selectable;
  @override
  Widget build(BuildContext context) => Container(
    key: ValueKey("detail-fact-$name"),
    padding: const EdgeInsets.symmetric(vertical: 12),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: context.theme.colors.border)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            name,
            style: context.theme.typography.body.sm.copyWith(
              color: context.theme.colors.mutedForeground,
            ),
          ),
        ),
        Expanded(
          flex: 2,
          child: selectable
              ? SelectableText(value, textAlign: TextAlign.right)
              : Text(value, textAlign: TextAlign.right),
        ),
      ],
    ),
  );
}

class _BalanceFacts extends StatelessWidget {
  const _BalanceFacts(this.row);
  final AccountTableEntry row;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      _AccountFact('可用余额', row.balance == '—' ? '未知' : row.balance),
      _AccountFact(
        '额度查询时间',
        row.queriedAt == null ? '未知' : creditTime(row.queriedAt!),
      ),
    ],
  );
}

class _ExpiryDetails extends StatelessWidget {
  const _ExpiryDetails({required this.row});
  final AccountTableEntry row;
  @override
  Widget build(BuildContext context) {
    final batches = row.expiryBatches;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BalanceFacts(row),
        const SizedBox(height: 22),
        Text(
          '已知到期批次',
          style: context.theme.typography.body.md.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        if (batches.isEmpty) const Text('平台未提供可核实的到期明细。'),
        for (final batch in batches)
          _AccountFact(creditTime(batch.at), batch.amount ?? '额度未知'),
        if (row.credits case final credits? when credits.withoutExpiry > 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('另有 ${accountPoints(credits.withoutExpiry)} 积分到期时间未知。'),
          ),
        if (row.expiryDetails != null) row.expiryDetails!,
        if (row.actions == null && row.onActivate != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Align(
              alignment: Alignment.centerRight,
              child: FButton(
                mainAxisSize: MainAxisSize.min,
                size: FButtonSizeVariant.sm,
                onPress: row.activationEnabled ? row.onActivate : null,
                child: const Text('切换客户端账号'),
              ),
            ),
          ),
      ],
    );
  }
}
