part of 'plugin_accounts_panel.dart';

bool _hasHeldPlan(PluginAccount a) => zcodePlans(_reward(a)).any(
  (plan) =>
      plan['status'] == 'active' &&
      zcodeTime(plan['ends_at'])?.isAfter(DateTime.now()) != false,
);

class _ZcodeGiftDetails extends StatelessWidget {
  const _ZcodeGiftDetails(this.account);
  final PluginAccount account;

  @override
  Widget build(BuildContext context) {
    final reward = _reward(account);
    final buckets = zcodeBuckets(reward).toList();
    final plans = zcodePlans(reward).toList();
    final rewardTime = _millis(reward['checkedAt']);
    final secondary = context.theme.typography.body.xs.copyWith(
      color: context.theme.colors.mutedForeground,
    );
    final heading = context.theme.typography.body.sm.copyWith(
      fontWeight: FontWeight.w600,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FDivider(),
        Text('已获活动额度', style: heading),
        Text(
          rewardTime == null
              ? '活动额度观测时间未知'
              : '活动额度观测于 ${creditTime(rewardTime)}',
          style: secondary,
        ),
        const SizedBox(height: 8),
        for (final p in plans) ...[
          Text(_text(p['name']) ?? '活动套餐', style: heading),
          for (final entitlement in zcodeEntitlements(p))
            Text(
              [
                if (_text(entitlement['show_name']) case final name?) name,
                if (zcodeUnits(entitlement['grant_units']) case final amount?)
                  '${switch (entitlement['period']) {
                    'daily' => '每日发放',
                    'weekly' => '每周发放',
                    'monthly' => '每月发放',
                    _ => '发放',
                  }} ${_number(amount)} ${_text(entitlement['unit_type']) ?? '单位未知'}',
                if (zcodeTime(entitlement['effective_at'] ?? p['starts_at'])
                    case final at?)
                  '${creditTime(at)} 生效',
              ].join(' · '),
            ),
          if (zcodeTime(p['ends_at']) case final at?)
            Text('${creditTime(at)} 到期'),
        ],
        if (buckets.isEmpty)
          Text(
            plans.isNotEmpty
                ? '本次查询尚无可用余额明细。'
                : rewardTime == null
                ? '尚无已核实的活动额度明细。'
                : '本次查询未返回活动权益。',
          ),
        for (final bucket in buckets)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              [
                '${bucket.label}：剩余 ${_number(bucket.remaining)} ${bucket.unit}',
                if (account.usesZcodeRewardExpiry)
                  if (zcodeTime(bucket.expiresAt) case final at?)
                    '${creditTime(at)} 到期',
              ].join(' · '),
            ),
          ),
      ],
    );
  }
}

List<ClaimReceipt> _zcodeReceipts(Map reward) {
  final receipts = <ClaimReceipt>[];
  final seen = <String>{};
  for (final claims in [
    reward['claims'],
    for (final binding
        in (reward['bindingHistory'] as List? ?? const []).reversed)
      if (binding is Map) binding['claims'],
  ].whereType<Map>()) {
    for (final entry in claims.entries) {
      if (entry.value is! Map) continue;
      final latest = entry.value as Map;
      for (final c in [
        latest,
        ...(latest['attempts'] as List? ?? const []).reversed,
      ].whereType<Map>()) {
        if (c['state'] != 'claimed') continue;
        final instance = c['instance'];
        if (instance is String && !seen.add(instance)) continue;
        final p = instance is String
            ? zcodePlans(reward)
                  .where(
                    (p) =>
                        p['plan_id'] == entry.key &&
                        p['user_plan_id'] == instance,
                  )
                  .singleOrNull
            : null;
        final grant = p == null ? null : zcodeReceiptAmount(p);
        final confirmed =
            c['serviceCode'] == 0 &&
            c['httpStatus'] == 200 &&
            c['errorCode'] == null &&
            c['observedAt'] == null;
        receipts.add(
          ClaimReceipt(
            amount: zcodeUnits(c['credit']) ?? grant?.amount,
            unit: _text(c['unit']) ?? grant?.unit ?? '单位未知',
            confirmedAt: confirmed ? _millis(c['answeredAt']) : null,
            observedAt: _millis(c['observedAt']),
            creditExpiresAt: zcodeTime(c['endsAt'] ?? p?['ends_at'])?.toLocal(),
          ),
        );
      }
    }
  }
  int timestamp(ClaimReceipt r) =>
      (r.confirmedAt ?? r.observedAt)?.millisecondsSinceEpoch ?? 0;
  receipts.sort((a, b) => timestamp(b).compareTo(timestamp(a)));
  return receipts;
}
