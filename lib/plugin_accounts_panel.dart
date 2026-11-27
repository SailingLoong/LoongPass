import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'claim_receipt.dart';
import 'compact_accounts_table.dart';
import 'credit_summary_view.dart';
import 'native_zcode_activity.dart';
import 'plugin_accounts.dart';
import 'plugin_credit_balance.dart';
import 'plugin_model_catalog.dart';
import 'plugin_rewards.dart';
import 'plugin_sign_in_dialog.dart';
import 'select_field_semantics.dart';
import 'plugin_zcode_binding.dart';
import 'zcode_api.dart';
import 'zcode_rewards.dart';

part 'plugin_zcode_quota_view.dart';

class PluginAccountsPanel extends StatefulWidget {
  const PluginAccountsPanel({
    super.key,
    required this.accounts,
    required this.rewards,
    required this.providerIds,
    required this.title,
    this.accountsWithoutModels = const {},
    this.modelCatalog = const [],
    this.activate,
    this.registrationUrl,
  });
  final PluginAccounts accounts;
  final PluginRewards rewards;
  final Set<String> providerIds;
  final Set<String> accountsWithoutModels;
  final List<PluginModel> modelCatalog;
  final String title;
  final Future<String> Function(String)? activate;
  final Uri? Function()? registrationUrl;
  @override
  PluginAccountsPanelState createState() => PluginAccountsPanelState();
}

class PluginAccountsPanelState extends State<PluginAccountsPanel> {
  Future<void> addAccount() => _authorize();

  bool _busy = false;
  bool _confirming = false;
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
          () => _message = e.code == 'device_required'
              ? '未能读取本机 ZCode 的设备 ID。请先打开官方客户端。'
              : '操作未完成，请核对授权与网络。待核验的领取记录会保留。',
        );
    } catch (_) {
      if (mounted) setState(() => _message = '操作未完成，请核对授权与网络。待核验的领取记录会保留。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _authorize([
    PluginAccount? account,
    bool bindLocal = false,
  ]) => _run(() async {
    if (widget.accounts.providers.isEmpty) {
      await widget.accounts.refresh();
      if (!mounted) return;
    }
    final zcode =
        account?.provider == 'zcode' ||
        account == null && widget.providerIds.contains('zcode');
    final localDevice = zcode ? await installedZcodeDevice() : null;
    if (bindLocal && localDevice == null)
      throw const ZcodeFailure('device_required');
    if (!mounted) return;
    final saved = await showFDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context, style, animation) => PluginSignInDialog(
        animation: animation,
        accounts: widget.accounts,
        providerIds: account == null ? widget.providerIds : {account.provider},
        initialProvider: account?.provider,
        target: account,
        localZcodeDevice: localDevice,
        preferLocalDevice: bindLocal,
        beforeDeviceChange: account == null
            ? null
            : () => widget.rewards.zcode.captureBinding(account.key),
        registrationUrl: account == null
            ? widget.registrationUrl?.call()
            : null,
        title: account == null
            ? '添加 ${widget.title} 账号'
            : '重新授权 ${account.label}',
      ),
    );
    if (saved != null && account?.provider == 'zcode' && localDevice != null) {
      try {
        await widget.rewards.zcode.captureBinding(saved);
      } on ZcodeFailure {
        if (mounted) setState(() => _message = '授权已保存，设备记录待下次刷新核验。');
        return;
      }
    }
    if (saved != null && mounted)
      setState(
        () => _message = account != null && saved != account.key
            ? '已保存新的授权账号，请核对列表中的账号身份。'
            : '账号授权已保存。',
      );
  }, accountKey: account?.key);

  Future<void> _refresh() => _run(() async {
    await widget.accounts.refresh();
    await Future.wait([
      for (final account in widget.accounts.accounts)
        if (widget.providerIds.contains(account.provider) &&
            account.provider == 'zcode' &&
            account.active &&
            account.uid.isNotEmpty)
          widget.rewards.refresh(account.key),
    ]);
  });

  Future<void> _verifyResult(PluginAccount account) =>
      _run(() => widget.rewards.refresh(account.key), accountKey: account.key);

  Future<void> _claim(PluginAccount account) => _run(
    () => widget.rewards.claim(
      account.key,
      verify: account.provider == 'zcode' ? verifyNativeZcodeClaim : null,
    ),
    accountKey: account.key,
  );

  Future<void> _activate(PluginAccount account) async {
    if (!mounted || _busy || _confirming || !_canActivate(account)) return;
    final owner = widget.accounts;
    final activate = widget.activate!;
    _confirming = true;
    try {
      final confirmed = await showFDialog<bool>(
        context: context,
        builder: (context, style, animation) => FDialog(
          animation: animation,
          constraints: const BoxConstraints(minWidth: 280, maxWidth: 512),
          builder: (context, style) => Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '客户端账号',
                  style: context.theme.typography.body.xs.copyWith(
                    color: context.theme.colors.mutedForeground,
                  ),
                ),
                const SizedBox(height: 12),
                DefaultTextStyle(
                  style: style.titleTextStyle,
                  child: Text('切换 ${widget.title} 账号？'),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: DefaultTextStyle(
                      style: style.bodyTextStyle,
                      child: Text(
                        '${account.label}\n${_identity(account)}\n\n'
                        '如 ${widget.title} 正在运行，将请求关闭 ${widget.title}；'
                        '确认其完全退出后应用所选账号并自动打开客户端。'
                        '正在进行的任务可能中断，请先保存工作。'
                        '若客户端显示退出确认，取消关闭将停止本次切换。'
                        '操作后请在客户端核对实际账号。',
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    FButton(
                      key: const Key('plugin-activate-cancel'),
                      variant: FButtonVariant.ghost,
                      size: FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      child: const Text('取消'),
                      onPress: () => Navigator.pop(context, false),
                    ),
                    FButton(
                      key: const Key('plugin-activate-confirm'),
                      size: FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      child: const Text('确认切换'),
                      onPress: () => Navigator.pop(context, true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      if (!mounted ||
          confirmed != true ||
          !identical(owner, widget.accounts) ||
          !_canActivate(account))
        return;
      await _run(() async {
        final result = await activate(account.key);
        if (mounted && identical(owner, widget.accounts))
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
    } finally {
      _confirming = false;
    }
  }

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
                    variant: FButtonVariant.destructive,
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
      a.active && a.uid.trim().isNotEmpty && widget.rewards.supports(a);

  bool _canVerifyResult(PluginAccount a) =>
      _canClaim(a) &&
      !_needsAuthorization(a) &&
      a.registrationId.isNotEmpty &&
      (a.provider == 'zcode' ||
          widget.accounts.providers[a.provider]?['checkinStatus'] == true);

  bool _canActivate(PluginAccount a) =>
      widget.activate != null &&
      a.provider == 'workbuddy' &&
      a.uid.isNotEmpty &&
      a.source != 'desktop';

  ({String label, VoidCallback run})? _resolution(PluginAccount a) {
    if (_busy) return null;
    if (_needsAuthorization(a))
      return (label: '重新授权', run: () => _authorize(a));
    if (_pending(a) && _canVerifyResult(a))
      return (label: '核验结果', run: () => _verifyResult(a));
    return null;
  }

  AccountAttention _attention(PluginAccount a) {
    final state = _rewardState(a);
    if (_needsAuthorization(a) ||
        {
          'captcha',
          'verificationRequired',
          'activationRequired',
          'device_required',
        }.contains(state)) {
      return AccountAttention.actionRequired;
    }
    // Without a status hook the generic owner can record an unknown outcome
    // even though no observation was attempted.
    final incompleteObservation =
        _canClaim(a) &&
        (a.provider == 'zcode' &&
                {
                  'discoveryIncomplete',
                  'devicePending',
                  'unavailable',
                }.contains(state) ||
            state == 'unknown' &&
                widget.accounts.providers[a.provider]?['checkinStatus'] ==
                    true);
    return _pending(a) ||
            incompleteObservation ||
            _usageFailure(a) != null ||
            a.error != null
        ? AccountAttention.awaitingVerification
        : AccountAttention.none;
  }

  Widget _actions(PluginAccount a) {
    final pending = _pending(a);
    final verify = pending && _canVerifyResult(a);
    final state = _rewardState(a);
    final primary = _needsAuthorization(a)
        ? 'authorize'
        : verify
        ? 'verify'
        : pending || state == 'devicePending'
        ? 'refresh'
        : _usageFailure(a) != null &&
              !(a.provider == 'zcode' && state == 'claimable')
        ? 'refresh'
        : _canClaim(a) &&
              {'claimable', 'verificationRequired', 'captcha'}.contains(state)
        ? 'claim'
        : _canActivate(a)
        ? 'activate'
        : 'refresh';
    final actions =
        <({String id, String label, bool enabled, VoidCallback run})>[
          (
            id: 'refresh',
            label: '刷新额度',
            enabled: !_busy && a.active,
            run: () => _run(
              () => _canClaim(a)
                  ? widget.rewards.refresh(a.key, includeUsage: true)
                  : widget.accounts.refresh(),
              accountKey: a.key,
            ),
          ),
          if (verify)
            (
              id: 'verify',
              label: '核验领取结果',
              enabled: !_busy,
              run: () => _verifyResult(a),
            ),
          if (!pending && _canClaim(a))
            (
              id: 'claim',
              label: {'verificationRequired', 'captcha'}.contains(state)
                  ? '完成官方验证'
                  : a.provider == 'zcode'
                  ? '核对并领取活动'
                  : '核对并领取',
              enabled: !_busy && !_needsAuthorization(a),
              run: () => _claim(a),
            ),
          if (_canActivate(a))
            (
              id: 'activate',
              label: '切换客户端账号',
              enabled: !_busy && a.active,
              run: () => _activate(a),
            ),
          (
            id: 'authorize',
            label: '重新授权',
            enabled: !_busy,
            run: () => _authorize(a),
          ),
          if (a.provider == 'zcode' &&
              a.uid.isNotEmpty &&
              widget.accounts.providers[a.provider]?['reauthorize'] == true)
            (
              id: 'rebind',
              label: '重新绑定设备',
              enabled: !_busy && a.active,
              run: () => _authorize(a, true),
            ),
          (id: 'remove', label: '移除账号', enabled: !_busy, run: () => _remove(a)),
        ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final action in actions.where(
          (v) => v.id == primary || v.id == 'refresh',
        ))
          FButton(
            variant: action.id == primary
                ? FButtonVariant.primary
                : FButtonVariant.outline,
            size: FButtonSizeVariant.sm,
            mainAxisSize: MainAxisSize.min,
            onPress: action.enabled ? action.run : null,
            child: Text(action.label),
          ),
        FPopoverMenu(
          menuAnchor: Alignment.topRight,
          childAnchor: Alignment.bottomRight,
          menuBuilder: (context, controller, _) => [
            FItemGroup(
              children: [
                for (final action in actions.where(
                  (v) => v.id != primary && v.id != 'refresh',
                ))
                  FItem(
                    title: Text(action.label),
                    enabled: action.enabled,
                    variant: action.id == 'remove'
                        ? FItemVariant.destructive
                        : FItemVariant.primary,
                    onPress: () async {
                      await controller.hide();
                      action.run();
                    },
                  ),
              ],
            ),
          ],
          builder: (context, controller, _) => FButton(
            variant: FButtonVariant.ghost,
            size: FButtonSizeVariant.sm,
            mainAxisSize: MainAxisSize.min,
            onPress: _busy ? null : controller.toggle,
            suffix: const Icon(FLucideIcons.chevronDown, size: 14),
            child: const Text('更多操作'),
          ),
        ),
      ],
    );
  }

  Widget? _expiryObservation(PluginAccount a) {
    if (a.provider != 'zcode') return null;
    final activity = a.usesZcodeRewardExpiry;
    if (!activity && a.usage == null) return null;
    final time = a.creditExpiryObservedAt;
    final source = activity ? '活动余额' : '套餐与额度';
    return Text(
      '到期数据来源：$source · ${time == null ? '观测时间未知' : creditTime(time)}',
      style: context.theme.typography.body.xs.copyWith(
        color: context.theme.colors.mutedForeground,
      ),
    );
  }

  Widget _quotaDetails(PluginAccount a) {
    final plan = _text(a.usage?['plan']), summary = _usageBalance(a.usage);
    final until = _date(a.usage?['until']), windows = _windows(a);
    final secondary = context.theme.typography.body.xs.copyWith(
      color: context.theme.colors.mutedForeground,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (a.provider == 'zcode') ...[
          FSelect<bool>(
            key: ValueKey('zcode-plan-${a.key}'),
            builder: selectFieldSemantics,
            label: const Text('模型调用可用额度'),
            items: const {'仅赠送额度（含 Start Plan）': true, '全部 Plan（赠送优先）': false},
            size: FTextFieldSizeVariant.sm,
            enabled: !_busy && a.active,
            control: FSelectControl.lifted(
              value: a.zcodeGiftOnly,
              onChange: (value) {
                if (value != null && value != a.zcodeGiftOnly) {
                  _run(
                    () => widget.accounts.setZcodeGiftOnly(a, value),
                    accountKey: a.key,
                  );
                }
              },
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (plan == null &&
            summary == null &&
            until == null &&
            windows.isEmpty) ...[
          if (a.provider != 'zcode') const Text('尚无可展示的官方套餐或窗口明细。'),
        ] else ...[
          Text(
            a.queriedAt == null
                ? '套餐与额度观测时间未知'
                : '套餐与额度观测于 ${creditTime(a.queriedAt!)}',
            style: secondary,
          ),
          if (plan != null) Text('套餐：$plan'),
          if (summary != null) Text('官方额度摘要：$summary'),
          if (until != null) Text('套餐到期：${creditTime(until)}'),
          if (windows.length > 1) Text('各额度窗口独立列出，可能重叠，不合计。', style: secondary),
          for (final window in windows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_windowText(window)),
                  if (window['display'] is String &&
                      (window['display'] as String).isNotEmpty)
                    Text('官方摘要：${window['display']}', style: secondary),
                  if (window['aside'] == true) const Text('参考额度'),
                  if (a.provider == 'zcode' && !a.usesZcodeRewardExpiry)
                    if (_date(window['runsOutAt']) case final expiry?)
                      Text('额度到期：${creditTime(expiry)}'),
                  if (_date(window['resetsAt']) case final reset?
                      when _date(window['runsOutAt'])
                              ?.isAtSameMomentAs(reset) !=
                          true)
                    Text('窗口重置：${creditTime(reset)}'),
                ],
              ),
            ),
        ],
        if (a.provider == 'zcode')
          if (_usageFailure(a) case final failure?) Text(failure),

        if (a.provider == 'zcode') _ZcodeGiftDetails(a),
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
                '通过官方授权保存多个账号。授权保存在本机应用私有目录；应用运行期间可辅助领取。'
                '同一活动的领取回执未确认时不会重复提交。各额度窗口保留官方单位，不合计重叠额度。',
            actions: [
              FButton(
                variant: FButtonVariant.primary,
                size: FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                prefix: const Icon(FLucideIcons.plus, size: 16),
                child: const Text('添加账号'),
                onPress: _busy ? null : addAccount,
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
          CompactAccountsTable(entries: rows.map(_entry).toList()),
        ],
      );
    },
  );
  AccountTableEntry _entry(PluginAccount a) {
    final batches = a.creditExpiryBatches;
    final next = nextPluginCreditExpiry(batches);
    final expiryBatches = [
      for (final batch in batches)
        (at: batch.at.toLocal(), amount: _formatBalance(batch.amount)),
    ];
    final expiryObservation = _expiryObservation(a);
    final receipts = _receipts(a).toList(growable: false);
    final receipt = receipts.firstOrNull;
    return AccountTableEntry(
      id: a.key,
      label: a.label.isEmpty ? '身份未提供' : a.label,
      identity: _identity(a),
      noAvailableModels: widget.accountsWithoutModels.contains(a.key),
      detailPlatform: [
        widget.title,
        if (a.realm.isNotEmpty) a.realm,
      ].join(' · '),
      officialId: a.uid.isEmpty ? null : a.uid,
      deviceBinding: a.provider == 'zcode'
          ? zcodeBindingLabel(a, widget.accounts.accounts) ?? '尚未核实'
          : null,
      authorizationLabel: _needsAuthorization(a) ? '需要重新授权' : '已保存授权',
      balance: _balance(a),
      status: _status(a),
      statusLabel: _statusLabel(a),
      highlightStatus: _rewardState(a) == 'claimable',
      hasRewards: widget.rewards.supports(a) || _pending(a) || receipt != null,
      actions: _actions(a),
      expiryDetails: expiryObservation,
      details: _quotaDetails(a),
      plan:
          _text(a.usage?['plan']) ??
          (a.provider == 'zcode'
              ? _text(
                  zcodePlans(_reward(a))
                      .where((p) => p['status'] == 'active')
                      .map((p) => _text(p['name']))
                      .whereType<String>()
                      .toSet()
                      .join(' · '),
                )
              : null),
      observedAt: a.balanceObservedAt,
      receipt: receipt,
      previousReceipts: receipts.skip(1).toList(growable: false),
      notice: _messageAccount == a.key ? _message : null,
      expiryAt: next?.at,
      expiringAmount: _formatBalance(next?.amount),
      attention: _attention(a),
      resolution: _resolution(a),
      expiryBatches: expiryBatches,
      expiryModels: {
        for (var i = 0; i < batches.length; i++)
          expiryBatches[i]: spendableModels(
            widget.modelCatalog,
            a,
            batches[i],
            batches,
            DateTime.now(),
          ),
      },
      onActivate: _canActivate(a) ? () => _activate(a) : null,
      activationEnabled: !_busy && a.active,
    );
  }
}

Map _reward(PluginAccount a) =>
    a.facts['reward'] is Map ? a.facts['reward'] : const {};
bool _needsAuthorization(PluginAccount a) =>
    !a.active ||
    a.error == 'authorization_required' ||
    a.usage?['signIn'] == 'expired' ||
    _rewardState(a) == 'authorization_required';

bool _pending(PluginAccount a) =>
    {'pending', 'unknown'}.contains(_reward(a)['status']) &&
    (a.provider != 'zcode' || zcodeText(_reward(a)['planId']));
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
String? _usageBalance(Map? usage) => _text(usage?['balance']);
String? _usageFailure(PluginAccount a) {
  if (a.error == 'authorization_required' || a.usage?['signIn'] == 'expired')
    return '额度授权已失效，请重新授权后刷新。';
  if (a.error == 'usage_unavailable' || _text(a.usage?['error']) != null)
    return a.provider == 'zcode' ? '套餐额度查询未完成。' : '最近一次额度查询未完成，请核对授权、权益或网络。';
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
String _windowText(Map w) {
  final unit = _unit(w);
  final name = _text(w['name']) ?? '额度窗口';
  final display = _text(w['display']);
  // Native informational rows may carry a zero share without a quantity.
  if (w['aside'] == true &&
      display != null &&
      (w['used'] ?? 0) == 0 &&
      (w['amount'] ?? 0) == 0 &&
      (w['limit'] ?? 0) == 0 &&
      w['balance'] == null)
    return '$name：$display';
  final values = [
    if (w['balance'] is num) '余额 ${_number(w['balance'])} $unit',
    if (w['amount'] is num) '已用 ${_number(w['amount'])} $unit',
    if (w['limit'] is num) '上限 ${_number(w['limit'])} $unit',
    if (w['used'] is num) '使用率 ${_number(w['used'])}%',
  ];
  return '$name：${values.isEmpty ? display ?? '数值未知' : values.join(' · ')}';
}

String _balance(PluginAccount a) {
  final balance = a.creditBalance;
  if (balance != null)
    return '${accountPoints(balance.amount)} ${balance.unit}';
  if (a.provider == 'zcode' &&
      a.usesZcodeRewardExpiry &&
      _usageFailure(a) == null) {
    final plans = zcodePlans(_reward(a)).toList();
    if (plans.isEmpty && _text(a.usage?['plan']) == null && _windows(a).isEmpty)
      return '暂无活动额度';
    final grants = plans
        .where((p) => p['status'] == 'active')
        .expand(zcodeEntitlements);
    if (grants.isNotEmpty &&
        grants.every(
          (e) => zcodeTime(e['effective_at'])?.isAfter(DateTime.now()) == true,
        ))
      return '待生效';
  }
  return '—';
}

String _status(PluginAccount a) {
  final failure = a.provider == 'zcode' ? '' : _usageFailure(a) ?? '';
  if (_pending(a)) return '未能确认本次领取的官方回执。同一活动不会重复提交。$failure';
  if (!a.active) return '需要重新授权。';
  final state = _rewardState(a);
  final reward = switch (state) {
    'claimed' => '已确认领取。',
    'done' || 'observedClaimed' => '官方确认已有权益。',
    'claimable' when a.provider == 'zcode' => '官方已向这个账号与绑定设备投放活动，领取资格由官方核验。',
    'claimable' => '当前有可领取活动。',
    'noOffer' when a.provider == 'zcode' && _hasHeldPlan(a) =>
      '已有活动权益，本次未收到新的可领取活动。',
    'noOffer' when a.provider == 'zcode' => '官方本次未向这个账号与绑定设备返回可领取活动。',
    'device_required' => '无法核对这个账号的绑定设备，活动资格待核对。',
    'devicePending' => '这台设备已有另一个账号提交了本次活动，正在等待官方回执。',
    'deviceClaimed' => '这台设备已通过另一个账号领取过本次活动。',
    'noOffer' || 'inactive' => '当前没有可领取活动。',
    'captcha' || 'verificationRequired' => '需要完成官方验证。',
    'activationRequired' => '请先使用官方客户端完成活动要求。',
    'ineligible' => '本次不符合官方领取条件。',
    'notSubmitted' => '本次领取请求未发送，可以重新核对活动。',
    'rejected' => '官方未接受本次领取。',
    'throttled' => '官方请求受限，请稍后再试。',
    'unavailable' || 'unknown' => '暂未取得官方活动状态。',
    'authorization_required' => '授权需要更新，请重新授权。',
    'discoveryIncomplete' => '活动信息暂不完整。',
    _ =>
      failure.isNotEmpty
          ? ''
          : a.error == null
          ? '等待官方额度与领取检查。'
          : '最近一次查询未完成。',
  };
  if (a.provider == 'zcode') {
    final facts = _reward(a), claims = facts['claims'];
    final claim = claims is Map ? claims[facts['planId']] : null;
    final reason = claim is Map && claim['state'] == state
        ? _text(claim['message'])
        : null;
    if (reason != null) return [reward, reason].join('\n');
  }
  return '$reward$failure';
}

String _statusLabel(PluginAccount a) {
  if (!a.active ||
      a.error == 'authorization_required' ||
      a.usage?['signIn'] == 'expired')
    return '需要重新授权';
  if (_pending(a)) return '领取回执未确认';
  if (a.provider != 'zcode' && _usageFailure(a) != null) return '额度查询未完成';
  return switch (_rewardState(a)) {
    'claimed' => '已确认领取',
    'done' || 'observedClaimed' => '官方已确认权益',
    'claimable' when a.provider == 'zcode' => '已收到活动',
    'claimable' => '有可领取活动',
    'noOffer' when a.provider == 'zcode' && _hasHeldPlan(a) => '已有活动权益',
    'noOffer' when a.provider == 'zcode' => '本账号与设备未收到活动',
    'device_required' => '绑定设备待核对',
    'devicePending' => '同设备领取待确认',
    'deviceClaimed' => '本设备已领取',
    'captcha' || 'verificationRequired' => '需要官方验证',
    'activationRequired' => '需要完成官方活动要求',
    'authorization_required' => '需要重新授权',
    'ineligible' => '不符合本次领取条件',
    'notSubmitted' => '领取请求未发送',
    'rejected' => '官方拒绝领取',
    'throttled' => '官方请求受限',
    'unavailable' || 'unknown' => '活动查询未完成',
    'noOffer' || 'inactive' => '暂无可领取活动',
    'discoveryIncomplete' => '活动信息暂不完整',
    _ =>
      _usageFailure(a) != null
          ? '额度查询未完成'
          : a.error != null
          ? '最近查询未完成'
          : '已保存',
  };
}

String? _rewardState(PluginAccount account) {
  final reward = _reward(account);
  if (account.provider == 'zcode') {
    if ({'pending', 'unknown'}.contains(reward['status']) &&
        !zcodeText(reward['planId'])) {
      return 'discoveryIncomplete';
    }
    return reward['status'] as String?;
  }
  return reward['status'] == 'unavailable'
      ? reward['outcome'] as String?
      : reward['status'] as String?;
}

Iterable<ClaimReceipt> _receipts(PluginAccount a) sync* {
  final reward = _reward(a);
  if (a.provider != 'zcode') {
    for (final r in [
      reward,
      ...(reward['history'] as List? ?? const []).reversed,
    ]) {
      if (r is Map && {'claimed', 'done'}.contains(r['status'])) {
        yield ClaimReceipt(
          amount: r['credit'] is num ? r['credit'] : null,
          unit: _unit(r),
          confirmedAt: _millis(r['confirmedAt']),
          observedAt: _millis(r['observedAt']),
          creditExpiresAt: _date(r['creditExpiresAt']),
          day: r['day'] is String ? r['day'] : null,
        );
      }
    }
    return;
  }
  yield* _zcodeReceipts(reward);
}

String? _formatBalance(PluginCreditBalance? amount) =>
    amount == null ? null : '${accountPoints(amount.amount)} ${amount.unit}';
