import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'native_account_gate.dart';
import 'zcode_flutter.dart';
import 'zcode_native.dart';
import 'zcode_promotions.dart';
import 'zcode_workspace.dart';

class ZcodeAccountsPanel extends StatefulWidget {
  const ZcodeAccountsPanel({super.key, this.workspace});
  /// Injection is for isolated verification. The panel owns and disposes its
  /// workspace; production never enables the validation gate here.
  final ZcodeWorkspace? workspace;
  @override State<ZcodeAccountsPanel> createState() => _ZcodeAccountsPanelState();
}

class _ZcodeAccountsPanelState extends State<ZcodeAccountsPanel> {
  late ZcodeWorkspace _owner;
  ZcodeWorkspace _create() {
    final channel = ZcodeMethodChannel();
    return ZcodeWorkspace(native: ZcodeNativeClient(call: channel.call),
      promotions: ZcodePromotionsClient(call: channel.call),
      nativeValidated: zcodeNativeAdapterValidated && nativeAccountAdaptersValidated &&
        defaultTargetPlatform == TargetPlatform.macOS);
  }
  @override void initState() {
    super.initState();
    _owner = widget.workspace ?? _create();
    _owner.addListener(_changed);
  }
  @override void didUpdateWidget(covariant ZcodeAccountsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.workspace, widget.workspace)) {
      _owner.removeListener(_changed);
      _owner.dispose();
      _owner = widget.workspace ?? _create();
      _owner.addListener(_changed);
    }
  }
  void _changed() { if (mounted) setState(() {}); }
  @override void dispose() {
    _owner.removeListener(_changed);
    _owner.dispose();
    super.dispose();
  }

  Future<void> _confirm(String title, String body,
      Future<void> Function() action) async {
    final owner = _owner;
    final agreed = await showDialog<bool>(context: context,
      builder: (context) => AlertDialog(title: Text(title), content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('继续')),
        ]));
    if (agreed == true && mounted && identical(owner, _owner) && !owner.disposed) {
      await action();
    }
  }

  String _nativeStatus(ZcodeStatus status) => status.available
      ? '原生上下文可用' : switch (status.reason) {
        'NativeCaptureRequired' => '请先显式捕获当前账号，核实当前版本。',
        'WritersActive' => 'ZCode 仍在写入，请先请求退出并核对状态。',
        'NativeContextUnavailable' => '原生上下文不可用（NativeContextUnavailable）。',
        _ => '当前不可用（${status.reason ?? 'NativeContextUnavailable'}）。',
      };
  String _promotionStatus(String status) => switch (status) {
    'claimable' => '服务端预览显示当前可领取，尚未领取。',
    'claimed' => '原生已确认该活动已领取。',
    'noClaim' => '服务端当前没有可领取活动。',
    'verificationRequired' => '需要人工验证码，尚未接线，不会自动重发。',
    'loginExpired' => '登录已过期，请在官方客户端重新登录后捕获。',
    'resultPending' => '领取结果待确认；不会自动重发，请重新检查。',
    'cancelled' => '本次活动操作已取消。',
    _ => '活动状态未知；请检查预览，不代表领取成功。',
  };
  String _time(int seconds) => DateTime.fromMillisecondsSinceEpoch(
    seconds * 1000, isUtc: true).toIso8601String().replaceFirst('T', ' ');

  @override Widget build(BuildContext context) {
    final owner = _owner, selected = _owner.selected, promotion = _owner.promotion;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('ZCode 同机账号切换与半夜、周末活动。账号列表仅保留在本次内存；凭据、恢复记录和活动领取校验由原生层管理。'),
      if (!owner.nativeValidated) const Padding(padding: EdgeInsets.only(top: 12),
        child: Text('Mac 原生验收尚未完成，真实操作默认关闭（NativeContextUnavailable）。打开页面不会读取账号、访问网络或写入文件。')),
      const SizedBox(height: 12),
      Text(_nativeStatus(owner.nativeStatus)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton(key: const Key('zcode-status'),
          onPressed: owner.canUseNative ? owner.refreshStatus : null,
          child: const Text('检查原生状态')),
        OutlinedButton(key: const Key('zcode-stop'),
          onPressed: owner.canUseNative ? () => _confirm('请求退出 ZCode',
            '请先保存 ZCode 中的工作。此操作只请求退出，仍须由原生层确认写入进程已停止。', owner.requestStop) : null,
          child: const Text('请求退出 ZCode')),
        OutlinedButton(key: const Key('zcode-capture-current'),
          onPressed: owner.canCapture ? owner.captureCurrent : null,
          child: const Text('捕获当前账号')),
        OutlinedButton(key: const Key('zcode-capture-selected'),
          onPressed: owner.canCapture ? owner.captureSelected : null,
          child: const Text('选择并捕获账号')),
      ]),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(key: const Key('zcode-selected-account'),
        initialValue: selected?.accountId, isExpanded: true,
        decoration: const InputDecoration(labelText: '本次内存中的目标账号'),
        items: [for (final account in owner.accounts)
          DropdownMenuItem(value: account.accountId,
            child: Text('${account.label ?? '已捕获账号'} · ${account.family}', overflow: TextOverflow.ellipsis))],
        onChanged: owner.busy ? null : owner.selectAccount),
      const SizedBox(height: 8),
      Text(owner.current == null ? '尚未核实当前账号版本。切换前需捕获当前账号。'
        : '当前版本已捕获；切换时原生层会再次校验。'),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton(key: const Key('zcode-switch'),
          onPressed: owner.canSwitch ? () => _confirm('切换 ZCode 账号',
            '将切换到选中的账号。原生层会检查当前版本和写入进程，并保留有条件恢复所需记录；不会自动重试或重新打开应用。',
            owner.switchSelected) : null, child: const Text('切换到选中账号')),
        if (owner.canRestoreLast) OutlinedButton(key: const Key('zcode-restore-last'),
          onPressed: owner.busy ? null : () => _confirm('有条件恢复上次切换',
            '仅在原生确认当前状态与上次操作相符时恢复；状态已变化会拒绝，不保证恢复成功。', owner.restoreLast),
          child: const Text('有条件恢复上次切换')),
        OutlinedButton(key: const Key('zcode-restore-selected'),
          onPressed: owner.canRestoreSelected ? () => _confirm('选择恢复记录',
            '由原生选择器选择已有操作记录并再次核验。仅恢复对应账号切换，不是通用文件恢复；状态不符时会拒绝。',
            owner.restoreSelected) : null, child: const Text('选择记录并有条件恢复')),
        OutlinedButton(key: const Key('zcode-reopen'),
          onPressed: owner.canUseNative ? owner.reopen : null,
          child: const Text('重新打开 ZCode')),
      ]),
      if (owner.switchOutcomeUnknown) const Padding(padding: EdgeInsets.only(top: 12),
        child: Text('切换或恢复结果未知。未自动重试，也未自动回滚。请核对当前账号；如需恢复，请显式选择原生记录并重新核验。')),
      if (owner.lastOutcome case final String outcome)
        Padding(padding: const EdgeInsets.only(top: 8), child: Text(switch (outcome) {
          'switched' => '原生已确认切换完成；尚未重新打开 ZCode。',
          'restored' => '原生已确认有条件恢复完成。',
          _ => '原生确认没有修改。',
        })),
      const SizedBox(height: 24),
      const Text('半夜与周末活动', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      const Text('以服务端预览为准，不按本机日期推定活动窗口。当前原生响应不提供精确可领取时段。'),
      if (!owner.promotionStatus.available)
        Text(owner.promotionStatus.reason == 'CommitUncertain'
          ? '活动领取暂锁定（CommitUncertain）；仍可检查活动预览核实，不会重发领取。'
          : '活动接口不可用（${owner.promotionStatus.reason ?? 'NativeContextUnavailable'}）。'),
      Text(_promotionStatus(promotion.status)),
      if (promotion.planName case final String name) Text('活动：$name'),
      if (promotion.reason case final String reason) Text('状态原因：$reason'),
      if (promotion.startsAt != null || promotion.endsAt != null)
        const Text('以下为权益有效期，不代表活动开放窗口。'),
      if (promotion.startsAt case final int seconds) Text('权益生效（UTC）：${_time(seconds)}'),
      if (promotion.endsAt case final int seconds) Text('权益到期（UTC）：${_time(seconds)}'),
      if (promotion.checkedAt case final int seconds) Text('最近检查（UTC）：${_time(seconds)}'),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton(key: const Key('zcode-preview'),
          onPressed: owner.canPreview ? owner.previewPromotions : null,
          child: const Text('检查活动预览')),
        FilledButton(key: const Key('zcode-claim'),
          onPressed: owner.canClaim ? () => _confirm('领取当前活动',
            '将请求原生层再次核验并领取选中账号的活动。结果未知时不会重发，请重新检查；待确认记录由原生层保留。',
            owner.claimPromotions) : null, child: const Text('领取当前活动')),
      ]),
      SwitchListTile(key: const Key('zcode-automatic'), contentPadding: EdgeInsets.zero,
        title: const Text('本次会话自动检查并领取'),
        subtitle: const Text('每 10 分钟检查服务端活动，仅领取符合条件的活动。关闭页面会话、切换账号或变更上下文即关闭；结果未知时暂停。'),
        value: owner.automatic,
        onChanged: owner.automatic || owner.canEnableAutomatic ? owner.setAutomatic : null),
      if (owner.failureCode case final String code)
        Padding(padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('操作未完成（$code）。没有自动重试，请核对当前状态。')),
      if (owner.busy) const LinearProgressIndicator(),
    ]);
  }
}
