import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart' show SelectableText;

import 'claim_receipt.dart';
import 'compact_accounts_table.dart';
import 'credit_summary_view.dart';
import 'native_zcode_activity.dart';
import 'plugin_accounts.dart';
import 'plugin_rewards.dart';
import 'plugin_sign_in_dialog.dart';
import 'plugin_zcode_binding.dart';
import 'zcode_api.dart';
import 'zcode_rewards.dart';

class PluginAccountsPanel extends StatefulWidget {
  const PluginAccountsPanel({
    super.key,
    required this.accounts,
    required this.rewards,
    required this.providerIds,
    required this.title,
    this.activate,
    this.registrationUrl,
  });
  final PluginAccounts accounts;
  final PluginRewards rewards;
  final Set<String> providerIds;
  final String title;
  final Future<String> Function(String)? activate;
  final Uri? Function()? registrationUrl;
  @override
  State<PluginAccountsPanel> createState() => _PluginAccountsPanelState();
}

class _PluginAccountsPanelState extends State<PluginAccountsPanel> {
  bool _busy = false;
  String? _message;
  String? _messageAccount;

  Future<void> _run(
    Future<void> Function() action, {
    String? accountKey,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _messageAccount = accountKey;
    });
    try {
      await action();
    } on ZcodeFailure catch (e) {
      if (mounted)
        setState(
          () => _message = e.code == 'device_pool_empty'
              ? '没有可用的已保存设备号，账号设备未改变。'
              : '操作未完成，请核对授权与网络。待核验的领取记录会保留。',
        );
    } catch (_) {
      if (mounted) setState(() => _message = '操作未完成，请核对授权与网络。待核验的领取记录会保留。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _authorize([PluginAccount? account]) => _run(() async {
    final saved = await showFDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context, style, animation) => PluginSignInDialog(
        animation: animation,
        accounts: widget.accounts,
        providerIds: account == null ? widget.providerIds : {account.provider},
        initialProvider: account?.provider,
        target: account,
        registrationUrl: account == null
            ? widget.registrationUrl?.call()
            : null,
        title: account == null
            ? '添加 ${widget.title} 账号'
            : '重新授权 ${account.label}',
      ),
    );
    if (saved != null && mounted)
      setState(
        () => _message = account != null && saved != account.key
            ? '已保存新的授权账号，请核对列表中的账号身份。'
            : '账号授权已保存。',
      );
  }, accountKey: account?.key);

  Future<void> _rebind(PluginAccount account) => _run(() async {
    // Preserve the currently verified device before asking the native owner
    // for a new grant. This is a metadata commit, with no reward HTTP request.
    await widget.rewards.zcode.captureBinding(account.key);
    final reservation = await ZcodeDeviceReservation.take(
      widget.accounts,
      account,
    );
    try {
      if (!mounted) return;
      final saved = await showFDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context, style, animation) => PluginSignInDialog(
          animation: animation,
          accounts: widget.accounts,
          providerIds: {account.provider},
          initialProvider: account.provider,
          target: account,
          authorizationContext: {'device': reservation.device},
          title: '重新绑定 ${account.label} 的设备',
        ),
      );
      if (saved == null) return;
      try {
        await widget.rewards.zcode.captureBinding(saved);
        if (mounted) setState(() => _message = '已通过官方授权更新设备绑定。领取记录已保留。');
      } catch (_) {
        if (mounted) setState(() => _message = '官方授权已保存，设备历史尚待核验，请刷新活动记录。');
      }
    } finally {
      reservation.release();
    }
  }, accountKey: account.key);

  Future<void> _refresh() => _run(() async {
    await widget.accounts.refresh();
    for (final account in widget.accounts.accounts) {
      if (widget.providerIds.contains(account.provider) &&
          account.active &&
          account.provider == 'zcode')
        await widget.rewards.zcode.refresh(account.key);
    }
  });

  Future<void> _claim(PluginAccount account) => _run(() async {
    if (_pending(account)) {
      await widget.rewards.refresh(account.key);
    } else if (account.provider == 'zcode') {
      await widget.rewards.zcode.claim(
        account.key,
        verify: verifyNativeZcodeClaim,
      );
    } else {
      await widget.rewards.claim(account.key);
    }
  }, accountKey: account.key);

  Future<void> _activate(PluginAccount account) => _run(() async {
    final result = await widget.activate!(account.key);
    if (mounted)
      setState(
        () => _message = switch (result) {
          'opened' => '已应用授权并打开 WorkBuddy，请在客户端核对当前身份。',
          'applied' => '授权已应用，请打开 WorkBuddy 核对当前身份。',
          'cancelled' => '本次客户端切换已取消。',
          'expired' => '切换准备已超时，请重新操作。',
          'busy' => '未能确认 WorkBuddy 已完全退出，请保存工作并关闭客户端。',
          'recoveryRequired' => '客户端文件状态存在冲突，请核对恢复记录后再操作。',
          'unavailable' => '账号正在处理其他操作或授权需要核验，请稍后重试。',
          _ => '客户端切换结果待核对，请检查客户端当前身份。',
        },
      );
  }, accountKey: account.key);

  Future<void> _remove(PluginAccount account) async {
    final confirmed = await showFDialog<bool>(
      context: context,
      builder: (context, style, animation) => FDialog(
        animation: animation,
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 640),
        builder: (context, style) => Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DefaultTextStyle(
                style: style.titleTextStyle,
                child: const Text('移除已保存的账号？'),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: DefaultTextStyle(
                  style: style.bodyTextStyle,
                  child: const Text('将移除账号授权，保留领取记录，避免重新授权后重复领取。'),
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  FButton(
                    variant: FButtonVariant.ghost,
                    size: FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    child: const Text('取消'),
                    onPress: () => Navigator.pop(context, false),
                  ),
                  FButton(
                    variant: FButtonVariant.ghost,
                    size: FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    child: const Text('移除账号'),
                    onPress: () => Navigator.pop(context, true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed == true && mounted)
      await _run(
        () => widget.accounts.remove(account.key),
        accountKey: account.key,
      );
  }

  bool _canClaim(PluginAccount a) =>
      a.active &&
      a.uid.isNotEmpty &&
      (a.provider == 'zcode' ||
          widget.accounts.providers[a.provider]?['checkin'] == true);
  bool _canActivate(PluginAccount a) =>
      widget.activate != null &&
      a.provider == 'workbuddy' &&
      a.uid.isNotEmpty &&
      a.source != 'desktop';

  Widget _details(PluginAccount a) {
    final usage = a.usage, reward = _reward(a), buckets = _buckets(a);
    final rewardTime = _millis(reward['checkedAt'] ?? reward['observedAt']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(_identity(a)),
        Text(_status(a)),
        const SizedBox(height: 12),
        Text('官方套餐与额度', style: context.theme.typography.body.sm),
        if (usage == null)
          const Text('尚无可核实的官方额度快照。')
        else ...[
          if (_text(usage['plan']) case final plan?) Text('套餐：$plan'),
          if (_usageBalance(usage) case final balance?) Text('余额：$balance'),
          if (_date(usage['until']) != null)
            Text('套餐到期：${creditTime(_date(usage['until'])!)}'),
          if (_windows(a).isNotEmpty) const Text('各额度窗口独立列出，可能重叠，不合计。'),
          for (final window in _windows(a))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_windowText(window)),
                  if (window['display'] is String &&
                      (window['display'] as String).isNotEmpty)
                    Text(
                      '官方摘要：${window['display']}',
                      style: context.theme.typography.body.xs,
                    ),
                  if (window['aside'] == true) const Text('参考额度'),
                  if (_date(window['resetsAt']) != null)
                    Text('窗口重置：${creditTime(_date(window['resetsAt'])!)}'),
                  if (_date(window['runsOutAt']) != null)
                    Text(
                      '到期额度：${_number(window['runsOut'])} ${_unit(window)} · ${creditTime(_date(window['runsOutAt'])!)}',
                    ),
                ],
              ),
            ),
        ],
        if (a.provider == 'zcode' && _usageFailure(a) != null)
          const Text('若已开通 Coding Plan，请重新授权后核对套餐权益。'),
        Text(
          a.queriedAt == null
              ? '尚无成功的额度查询。'
              : '${_usageFailure(a) == null ? '查询于' : '上次成功查询于'} ${creditTime(a.queriedAt!)}',
        ),
        if (a.provider == 'zcode') ...[
          const FDivider(),
          Text('Start Plan 活动额度', style: context.theme.typography.body.sm),
          if (buckets.isEmpty)
            Text(
              reward['checkedAt'] == null
                  ? '尚无已核实的活动额度明细。'
                  : '本次查询未返回有效的 Start Plan 活动额度。',
            ),
          for (final bucket in buckets)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '${bucket.label}：剩余 ${_number(bucket.remaining)} ${bucket.unit}；'
                '${bucket.expiresAt == null ? '到期时间未知' : '${creditTime(DateTime.fromMillisecondsSinceEpoch(bucket.expiresAt! * 1000))} 到期'}',
              ),
            ),
          Text(
            rewardTime == null
                ? '活动额度查询时间未知'
                : '活动额度查询于 ${creditTime(rewardTime)}',
          ),
        ],
        const FDivider(),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FButton(
              variant: FButtonVariant.outline,
              size: FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              child: const Text('刷新额度'),
              onPress: _busy || !a.active
                  ? null
                  : () => _run(
                      () => _canClaim(a)
                          ? widget.rewards.refresh(a.key)
                          : widget.accounts.refresh(),
                      accountKey: a.key,
                    ),
            ),
            if (_canClaim(a) || _pending(a))
              FButton(
                variant: FButtonVariant.outline,
                size: FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                child: Text(
                  _pending(a)
                      ? '核验领取结果'
                      : a.provider == 'zcode'
                      ? '核对并领取活动'
                      : '核对并领取',
                ),
                onPress: _busy || !_canClaim(a) ? null : () => _claim(a),
              ),
            if (_canActivate(a))
              FButton(
                variant: FButtonVariant.outline,
                size: FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                child: const Text('切换客户端账号'),
                onPress: _busy || !a.active ? null : () => _activate(a),
              ),
            FButton(
              variant: FButtonVariant.ghost,
              size: FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              child: const Text('重新授权'),
              onPress: _busy ? null : () => _authorize(a),
            ),
            if (a.provider == 'zcode' &&
                a.uid.isNotEmpty &&
                widget.accounts.providers[a.provider]?['reauthorize'] == true)
              FButton(
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                child: const Text('重新绑定设备'),
                onPress: _busy || !a.active ? null : () => _rebind(a),
              ),
            FButton(
              variant: FButtonVariant.ghost,
              size: FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              child: const Text('移除账号'),
              onPress: _busy ? null : () => _remove(a),
            ),
          ],
        ),
        FSwitch(
          value: a.automatic,
          label: const Text('自动领取'),
          description: Text(
            a.uid.isEmpty ? '此授权未提供可核实的账号身份。' : '应用运行期间检查并领取；退出应用后停止。',
          ),
          leadingLabel: true,
          enabled: !(_busy || a.uid.isEmpty),
          onChange: (value) => _run(
            () => widget.accounts.setAutomatic(a.key, value),
            accountKey: a.key,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.accounts,
    builder: (context, _) {
      final rows = widget.accounts.accounts
          .where((a) => widget.providerIds.contains(a.provider))
          .toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AccountPanelToolbar(
            title: widget.title,
            accountCount: rows.length,
            helpText:
                '通过官方授权保存多个账号。授权保存在本机应用私有目录；应用运行期间可自动领取。'
                '领取结果待核验时只查询官方状态。各额度窗口保留官方单位，不合计重叠额度。',
            actions: [
              FButton(
                variant: FButtonVariant.primary,
                size: FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                child: const Text('添加账号'),
                onPress: _busy ? null : _authorize,
              ),
              FButton(
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                child: const Text('刷新账号与额度'),
                onPress: _busy ? null : _refresh,
              ),
            ],
          ),
          if (_busy) const FProgress(),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_message!),
            ),
          if (widget.accounts.error != null)
            const Text('最近一次查询未完成，当前保留已保存的结果。'),
          CompactAccountsTable(
            entries: [
              for (final a in rows)
                AccountTableEntry(
                  id: a.key,
                  label: a.label,
                  identity: _identity(a),
                  balance: _balance(a),
                  status: _status(a),
                  details: _details(a),
                  observedAt: a.queriedAt,
                  receipt: _receipt(a),
                  notice: _messageAccount == a.key ? _message : null,
                  expiryAt: _expiry(a),
                  expiryText: _expiryText(a),
                  needsAttention:
                      !a.active ||
                      a.error != null ||
                      _usageFailure(a) != null ||
                      _pending(a) ||
                      {
                        'captcha',
                        'verificationRequired',
                        'activationRequired',
                        'authorization_required',
                      }.contains(_reward(a)['status']),
                  onActivate: _canActivate(a) ? () => _activate(a) : null,
                  activationEnabled: !_busy && a.active,
                ),
            ],
          ),
        ],
      );
    },
  );
}

Map _reward(PluginAccount a) =>
    a.facts['reward'] is Map ? a.facts['reward'] : const {};
bool _pending(PluginAccount a) =>
    {'pending', 'unknown'}.contains(_reward(a)['status']);
String _identity(PluginAccount a) =>
    '${a.uid.isEmpty ? '身份未验证' : a.uid} · ${a.realm.isEmpty ? '地区未提供' : a.realm}';
String _unit(Map value) =>
    value['unit'] is String && (value['unit'] as String).isNotEmpty
    ? value['unit']
    : '单位未知';
String _number(Object? value) => value is num && value.isFinite
    ? value is int
          ? value.toString()
          : value == value.truncateToDouble()
          ? value.toStringAsFixed(0)
          : value.toString()
    : '未知';
DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;
String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;
String? _usageBalance(Map? usage) => usage?['balance'] is num
    ? '${_number(usage!['balance'])} ${_unit(usage)}'
    : _text(usage?['balance']);
String? _usageFailure(PluginAccount a) {
  if (a.error == 'authorization_required' || a.usage?['signIn'] == 'expired')
    return '额度授权已失效，请重新授权后刷新。';
  if (a.error == 'usage_unavailable' || _text(a.usage?['error']) != null)
    return '最近一次额度查询未完成，请核对授权、权益或网络。';
  return null;
}

DateTime? _millis(Object? value) =>
    value is int && value > 0 && value < 8640000000000000
    ? DateTime.fromMillisecondsSinceEpoch(value)
    : null;
List<Map> _windows(PluginAccount a) => [
  for (final w in a.usage?['windows'] as List? ?? const [])
    if (w is Map) w,
];
List<ZcodeBucket> _buckets(PluginAccount a) => [
  for (final b in _reward(a)['buckets'] as List? ?? const [])
    if (b is Map && b['label'] is String && b['unit'] is String)
      ZcodeBucket.fromJson(Map<String, dynamic>.from(b)),
];

String _windowText(Map w) {
  final unit = _unit(w);
  final values = [
    if (w['balance'] is num) '余额 ${_number(w['balance'])} $unit',
    if (w['amount'] is num) '已用 ${_number(w['amount'])} $unit',
    if (w['limit'] is num) '上限 ${_number(w['limit'])} $unit',
    if (w['used'] is num) '使用率 ${_number(w['used'])}%',
  ];
  return '${_text(w['name']) ?? '额度窗口'}：${values.isEmpty ? _text(w['display']) ?? '数值未知' : values.join(' · ')}';
}

String _balance(PluginAccount a) {
  final summary = _usageBalance(a.usage);
  final usage = [
    if (summary != null)
      summary
    else
      for (final w in _windows(a)) _windowText(w),
  ];
  final parts = [
    if (usage.isNotEmpty)
      '${_usageFailure(a) == null ? '' : '上次：'}${usage.join(' / ')}',
    if (a.provider == 'zcode')
      for (final b in _buckets(a))
        'Start Plan · ${b.label} ${_number(b.remaining)} ${b.unit}',
  ];
  if (parts.isEmpty) return _usageFailure(a) == null ? '尚无已核实余额' : '额度查询未完成';
  return parts.join(' / ');
}

String _status(PluginAccount a) {
  final failure = _usageFailure(a) ?? '';
  if (_pending(a)) return '待核验：不会重复发送领取请求。$failure';
  if (!a.active) return '需要重新授权。';
  final reward = switch (_reward(a)['status']) {
    'claimed' => '已确认领取。',
    'done' || 'observedClaimed' => '官方确认已有权益。',
    'claimable' => '当前有可领取活动。',
    'noOffer' || 'inactive' => '当前没有可领取活动。',
    'captcha' || 'verificationRequired' => '需要完成官方验证。',
    'activationRequired' => '请先使用官方客户端完成活动要求。',
    'ineligible' => '本次不符合官方领取条件。',
    'authorization_required' => '授权需要更新，请重新授权。',
    'discoveryIncomplete' => '活动信息暂不完整。',
    _ =>
      failure.isNotEmpty
          ? ''
          : a.error == null
          ? '等待官方额度与领取检查。'
          : '最近一次查询未完成。',
  };
  return '$reward$failure';
}

ClaimReceipt? _receipt(PluginAccount a) {
  final reward = _reward(a);
  for (final r in [
    reward,
    ...(reward['history'] as List? ?? const []).reversed,
  ]) {
    if (r is Map && {'claimed', 'done'}.contains(r['status']))
      return ClaimReceipt(
        amount: r['credit'] is num ? r['credit'] : null,
        unit: _unit(r),
        confirmedAt: _millis(r['confirmedAt']),
        observedAt: _millis(r['observedAt']),
        day: r['day'] is String ? r['day'] : null,
      );
  }
  for (final claims in [
    reward['claims'],
    for (final binding in reward['bindingHistory'] as List? ?? const [])
      if (binding is Map) binding['claims'],
  ]) {
    if (claims is Map &&
        claims.values.any((c) => c is Map && c['state'] == 'claimed')) {
      return const ClaimReceipt(unit: '单位未知');
    }
  }
  return null;
}

DateTime? _expiry(PluginAccount a) {
  final now = DateTime.now();
  final values = [
    for (final b in _buckets(a))
      if (b.expiresAt != null && b.remaining != 0)
        DateTime.fromMillisecondsSinceEpoch(b.expiresAt! * 1000),
    for (final w in _windows(a))
      if (w['runsOut'] != 0 && _date(w['runsOutAt']) != null)
        _date(w['runsOutAt'])!,
  ].where((d) => d.isAfter(now)).toList()..sort();
  return values.firstOrNull;
}

String? _expiryText(PluginAccount a) {
  final expiry = _expiry(a);
  if (expiry == null) return null;
  // Windows can overlap; preserve their quantities without adding them.
  final amounts = {
    for (final b in _buckets(a))
      if (b.expiresAt != null &&
          DateTime.fromMillisecondsSinceEpoch(b.expiresAt! * 1000)
              .isAtSameMomentAs(expiry) &&
          b.remaining != 0)
        '${_number(b.remaining)} ${b.unit}',
    for (final w in _windows(a))
      if (_date(w['runsOutAt'])?.isAtSameMomentAs(expiry) == true &&
          w['runsOut'] != 0)
        '${_number(w['runsOut'])} ${_unit(w)}',
  };
  return '${amounts.join(' / ')} · ${creditTime(expiry)} 到期';
}
