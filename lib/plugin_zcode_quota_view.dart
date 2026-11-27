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
    final planNames = {
      for (final p in plans)
        if (p['user_plan_id'] is String && p['name'] is String)
          p['user_plan_id']: p['name'],
    };
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
                if (_grantText(entitlement) case final grant?) grant,
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
                if (plans.length > 1)
                  if (planNames[bucket.instance] case final String name) name,
                bucket.label,
                '总量 ${_bucketAmount(bucket.total, bucket.unit)}',
                '已用 ${_bucketAmount(bucket.used, bucket.unit)}',
                '剩余 ${_bucketAmount(bucket.remaining, bucket.unit)}',
                if (bucket.models.isNotEmpty) '适用模型 ${bucket.models.join('、')}',
                if (zcodeTime(bucket.periodStart) case final at?)
                  '${creditTime(at)} 起算',
                if (zcodeTime(bucket.periodEnd) case final at?)
                  if (bucket.periodEnd != bucket.expiresAt)
                    '${creditTime(at)} 本期结束',
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

String _bucketAmount(num? amount, String unit) =>
    amount == null ? '未知' : groupAccountAmount('${_number(amount)} $unit');

String? _grantText(Map entitlement, {bool summary = false}) {
  final amount = zcodeUnits(entitlement['grant_units']);
  if (amount == null) return null;
  final period = switch (entitlement['period']) {
    'daily' => '每日发放',
    'weekly' => '每周发放',
    'monthly' => '每月发放',
    _ => summary ? '获赠' : '发放',
  };
  return '$period ${_bucketAmount(amount, _text(entitlement['unit_type']) ?? '单位未知')}';
}

List<String> _zcodeGiftGrants(PluginAccount account) {
  final now = DateTime.now();
  return [
    for (final p in zcodePlans(_reward(account)))
      if (p['status'] == 'active' &&
          zcodeTime(p['ends_at'])?.isAfter(now) != false)
        for (final e in zcodeEntitlements(p))
          if (_grantText(e, summary: true) case final grant?) grant,
  ];
}

Iterable<Map> _zcodeClaimGroups(Map reward) sync* {
  if (reward['claims'] case final Map claims) yield claims;
  if (reward['bindingHistory'] case final List history) {
    for (final previous in history.reversed.whereType<Map>()) {
      yield* _zcodeClaimGroups(previous);
    }
  }
}

List<DateTime> _zcodeUnconfirmedClaims(Map reward) {
  final pending = <(Object?, DateTime)>{}, settled = <(Object?, DateTime)>{};
  for (final claims in _zcodeClaimGroups(reward)) {
    for (final entry in claims.entries) {
      final claim = entry.value;
      if (claim is! Map) continue;
      final at = _millis(claim['submittedAt']);
      if (at == null) continue;
      final id = (entry.key, at);
      if ({'pending', 'unknown'}.contains(claim['state'])) {
        pending.add(id);
      } else {
        settled.add(id);
      }
    }
  }
  return pending.difference(settled).map((id) => id.$2).toList()
    ..sort((a, b) => b.compareTo(a));
}

List<ClaimReceipt> _zcodeReceipts(Map reward) {
  final receipts = <ClaimReceipt>[];
  final seen = <String>{};
  for (final claims in _zcodeClaimGroups(reward)) {
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
