part of 'account_details.dart';

extension on AccountDetailSection {
  String get title => switch (this) {
    AccountDetailSection.summary => '账号详情',
    AccountDetailSection.expiry => '到期明细',
    AccountDetailSection.receipt => '领取记录',
    AccountDetailSection.quota => '套餐与额度',
    AccountDetailSection.profile => '账号资料',
  };
}

String _shortTime(DateTime value) {
  final local = value.toLocal();
  final year = local.year == DateTime.now().year ? '' : '${local.year}年';
  return '$year${local.month}月${local.day}日 ${accountTime(local)}';
}

class _AccountSummary extends StatelessWidget {
  const _AccountSummary({required this.row, required this.onOpen});
  final AccountTableEntry row;
  final ValueChanged<AccountDetailSection> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final muted = theme.typography.body.xs.copyWith(
      color: theme.colors.mutedForeground,
    );
    final queried = row.queriedAt;
    final receipt = row.receipt;
    final expiry = row.nextExpiry;
    final receiptTime = receipt?.confirmedAt ?? receipt?.observedAt;
    final receiptNote = receipt == null
        ? '暂无已确认记录'
        : receiptTime == null
        ? receipt.timestamp
        : "${receipt.confirmedAt == null ? '核验于 ' : ''}${_shortTime(receiptTime)}";

    final balance = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '可用余额',
          style: theme.typography.body.sm.copyWith(
            color: theme.colors.mutedForeground,
          ),
        ),
        const SizedBox(height: 8),
        AccountAmount(
          row.balance,
          style: theme.typography.display.xl3.copyWith(
            fontSize: MediaQuery.sizeOf(context).width < 620 ? 34 : 43,
            height: 1.12,
            fontWeight: FontWeight.w600,
            letterSpacing: -1.3,
          ),
          unitStyle: theme.typography.body.sm.copyWith(
            height: 1.12,
            color: theme.colors.mutedForeground,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          queried == null ? '查询时间未知' : '${_shortTime(queried)} 查询',
          style: muted,
        ),
      ],
    );
    final metrics = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DetailLink(
          section: AccountDetailSection.expiry,
          label: '最近到期',
          icon: FLucideIcons.calendarDays,
          value: expiry == null
              ? null
              : row.upcomingExpiryAmount == '—'
              ? '额度未知'
              : groupAccountAmount(row.upcomingExpiryAmount),
          note: expiry == null ? '到期信息未知' : _shortTime(expiry),
          onOpen: onOpen,
        ),
        if (row.hasRewards)
          _DetailLink(
            section: AccountDetailSection.receipt,
            label: '最近领取',
            icon: FLucideIcons.history,
            value: receipt == null
                ? null
                : groupAccountAmount(receipt.quantity),
            note: receiptNote,
            onOpen: onOpen,
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (row.hasCredits) ...[
          LayoutBuilder(
            builder: (context, box) {
              if (box.maxWidth <
                  620 * MediaQuery.textScalerOf(context).scale(14) / 14) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [balance, const SizedBox(height: 22), metrics],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 24,
                      ),
                      decoration: BoxDecoration(
                        color: context.desktopPalette.sidebar,
                        borderRadius: theme.style.borderRadius.lg,
                      ),
                      child: balance,
                    ),
                  ),
                  const SizedBox(width: 28),
                  Expanded(child: metrics),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          _DetailLink(
            section: AccountDetailSection.quota,
            label: '套餐与额度',
            icon: FLucideIcons.layers,
            value: row.plan,
            note: row.giftGrants.isEmpty ? null : row.giftGrants.join('\n'),
            onOpen: onOpen,
          ),
        ] else ...[
          row.details,
          const SizedBox(height: 24),
        ],
        _DetailLink(
          section: AccountDetailSection.profile,
          label: '账号资料',
          icon: FLucideIcons.userRound,
          onOpen: onOpen,
        ),
      ],
    );
  }
}

class _DetailLink extends StatelessWidget {
  const _DetailLink({
    required this.section,
    required this.label,
    required this.icon,
    required this.onOpen,
    this.note,
    this.value,
  });
  final AccountDetailSection section;
  final String label;
  final String? value, note;
  final IconData icon;
  final ValueChanged<AccountDetailSection> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final labelStyle = theme.typography.body.md.copyWith(
      fontWeight: FontWeight.w600,
      height: 1.35,
    );
    final valueStyle = labelStyle.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
      color: note == null
          ? theme.colors.mutedForeground
          : theme.colors.foreground,
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 3,
          children: [
            Text(label, style: labelStyle),
            if (value != null) Text(value!, style: valueStyle),
          ],
        ),
        if (note != null) ...[
          const SizedBox(height: 4),
          Text(
            note!,
            maxLines: null,
            softWrap: true,
            overflow: TextOverflow.visible,
            style: theme.typography.body.xs.copyWith(
              color: theme.colors.mutedForeground,
              height: 1.35,
            ),
          ),
        ],
      ],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.colors.border)),
      ),
      child: FButton(
        key: ValueKey('detail-${section.name}'),
        variant: FButtonVariant.ghost,
        style: const FButtonStyleDelta.delta(
          contentStyle: FButtonContentStyleDelta.delta(
            padding: EdgeInsetsGeometryDelta.value(
              EdgeInsets.symmetric(horizontal: 8, vertical: 14),
            ),
          ),
        ),
        onPress: () => onOpen(section),
        mainAxisAlignment: MainAxisAlignment.start,
        prefix: DecoratedBox(
          decoration: BoxDecoration(
            color: note == null
                ? theme.colors.muted
                : context.desktopPalette.selected,
            borderRadius: theme.style.borderRadius.md,
          ),
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Icon(
              icon,
              size: 16,
              color: note == null
                  ? theme.colors.mutedForeground
                  : context.desktopPalette.selectedForeground,
            ),
          ),
        ),
        suffix: const Icon(FLucideIcons.chevronRight, size: 15),
        child: Expanded(child: text),
      ),
    );
  }
}

class _AccountProfile extends StatelessWidget {
  const _AccountProfile({required this.row, this.source});
  final AccountTableEntry row;
  final String? source;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Fact('账号名称', row.label),
      _Fact('平台', row.detailPlatform ?? source ?? '未知'),
      _Fact('账号 ID', row.officialId ?? '未提供'),
      if (row.deviceBinding case final device?) _Fact('绑定设备 ID', device),
      _Fact('授权状态', row.authorizationLabel ?? '未知'),
      if (row.hasRewards) _Fact('活动状态', row.status),
      if (row.hasCredits)
        _Fact(
          '额度查询时间',
          row.queriedAt == null ? '未知' : creditTime(row.queriedAt!),
        ),
    ],
  );
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value, {this.selected = false, super.key});
  final String label, value;
  final bool selected;
  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: Container(
      decoration: BoxDecoration(
        color: selected ? context.desktopPalette.selected : null,
        border: Border(bottom: BorderSide(color: context.theme.colors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        spacing: 10,
        runSpacing: 4,
        children: [
          Text(
            label,
            style: context.theme.typography.body.sm.copyWith(
              color: context.theme.colors.mutedForeground,
            ),
          ),
          SelectableText(value, style: context.theme.typography.body.sm),
        ],
      ),
    ),
  );
}

class _ExpiryDetails extends StatefulWidget {
  const _ExpiryDetails({required this.row, this.batch});
  final AccountTableEntry row;
  final AccountExpiryBatch? batch;
  @override
  State<_ExpiryDetails> createState() => _ExpiryDetailsState();
}

class _ExpiryDetailsState extends State<_ExpiryDetails> {
  final _target = GlobalKey();
  @override
  void initState() {
    super.initState();
    if (widget.batch != null)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _target.currentContext;
        if (target != null) Scrollable.ensureVisible(target, alignment: .35);
      });
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final batches = row.expiryBatches;
    final selected = widget.batch;
    final first = selected == null
        ? -1
        : batches.indexWhere(
            (b) =>
                selected.at.isAtSameMomentAs(b.at) &&
                selected.amount == b.amount,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (batches.isEmpty) const Text('平台未提供可核实的到期明细。'),
        for (var i = 0; i < batches.length; i++) ...[
          _Fact(
            creditTime(batches[i].at),
            batches[i].amount ?? '额度未知',
            selected: i == first,
            key: i == first ? _target : null,
          ),
          if ((first < 0 || i == first) &&
              row.expiryModels.containsKey(batches[i]))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Text(
                row.expiryModels[batches[i]]!.isEmpty
                    ? '暂无可核实的已开放模型'
                    : '可用模型  ${row.expiryModels[batches[i]]!.join('、')}',
              ),
            ),
        ],
        if (row.credits case final credits? when credits.withoutExpiry > 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('另有 ${accountPoints(credits.withoutExpiry)} 积分到期时间未知。'),
          ),
        if (row.expiryDetails != null) row.expiryDetails!,
      ],
    );
  }
}

class _Receipts extends StatelessWidget {
  const _Receipts(this.row);
  final AccountTableEntry row;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (row.receipt == null) const Text('暂无已确认记录'),
      for (final receipt in [?row.receipt, ...row.previousReceipts])
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(receipt.display),
        ),
      for (final submitted in row.unconfirmedClaimTimes)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text('${creditTime(submitted)} 提交 · 官方回执未确认'),
        ),
    ],
  );
}
