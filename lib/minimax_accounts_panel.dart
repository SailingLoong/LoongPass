import 'desktop_platform.dart';
import 'compact_accounts_table.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'native_minimax_accounts.dart';
import 'minimax_accounts.dart';
import 'credit_summary_view.dart';

class MiniMaxAccountsPanel extends StatefulWidget {
  const MiniMaxAccountsPanel({
    super.key,
    this.region = 'cn',
    this.open,
    this.owner,
  });
  final String region;
  final Future<MiniMaxAccounts> Function()? open;
  final MiniMaxAccounts? owner;
  @override
  State<MiniMaxAccountsPanel> createState() => _MiniMaxAccountsPanelState();
}

class _MiniMaxAccountsPanelState extends State<MiniMaxAccountsPanel> {
  static const _channel = MethodChannel('com.sailingloong.loongpass/files');
  MiniMaxAccounts? _service;
  StreamSubscription<void>? _subscription;
  List<MiniMaxAccount> _accounts = [];
  bool _busy = false;
  String? _message;
  bool get _available =>
      widget.owner != null || widget.open != null || nativeAccountsSupported;
  String get _name => widget.region == 'cn' ? 'MiniMax CN' : 'MiniMax';
  @override
  void initState() {
    super.initState();
    if (_available) unawaited(_restore());
  }

  Future<void> _restore() => _run(() async {
    final service =
        widget.owner ??
        (widget.open != null
            ? await widget.open!()
            : await openNativeMiniMaxAccounts(
                region: widget.region,
                onAutomaticFinished: _refresh,
              ));
    if (!mounted) {
      if (widget.owner == null) service.dispose();
      return;
    }
    _service = service;
    _subscription = service.changes.listen((_) => unawaited(_refresh()));
    await _refresh();
    if (widget.owner == null) service.startAutomatic();
  });
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _message = '操作未完成，请检查网络或本机保存状态。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    final service = _service;
    if (service == null || !mounted) return;
    final accounts = await service.list();
    if (mounted)
      setState(() {
        _accounts = accounts.where((a) => a.region == widget.region).toList();
        _message = service.loginMessage ?? _message;
      });
  }

  Future<void> _authorize() => _run(() async {
    final service = _service;
    if (service == null) return;
    final uri = await service.beginAuthorization(widget.region);
    if (!mounted) {
      service.cancelAuthorization();
      return;
    }
    await _channel.invokeMethod<void>('openMiniMaxAuthorization', {
      'url': uri.toString(),
      'region': widget.region,
    });
    service.pollAuthorization();
    await _refresh();
  });
  String _status(MiniMaxAccount a) => switch (a.status) {
    'claimed' => '服务端已确认本次领取 ${a.points ?? ''} 积分。',
    'alreadyClaimed' => '本周期已签到。',
    'unknown' => '领取结果未知，已停止重复发送。',
    'needsLogin' => '授权已过期，请重新授权此账号。',
    'claimable' => '当前可签到。',
    _ => '等待下一次签到检查。',
  };
  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    if (widget.owner == null) _service?.dispose();
    super.dispose();
  }

  Widget _details(MiniMaxAccount a) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(a.label, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(a.uid),
          Text(_status(a)),
          if (a.rewardExpiresAtMs case final int expires)
            Text(
              '最近领取批次：${a.points} 积分 · ${DateTime.fromMillisecondsSinceEpoch(expires)} 到期（发放记录，剩余未核实）',
            ),
          if (_service!.credits(a.id) case final summary?)
            CreditSummaryView(summary: summary),
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await _service!.refreshCredits(a.id);
                        await _refresh();
                      }),
                child: const Text('查询余额与到期'),
              ),
              OutlinedButton(
                onPressed: _busy || a.status == 'unknown'
                    ? null
                    : () => _run(() async {
                        await _service!.claim(a.id);
                        await _refresh();
                      }),
                child: const Text('核对并签到'),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('自动签到'),
                  Switch(
                    value: a.automatic,
                    onChanged: _busy
                        ? null
                        : (enabled) => _run(() async {
                            await _service!.setAutomatic(a.id, enabled);
                            if (enabled) _service!.startAutomatic();
                            await _refresh();
                          }),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      AccountPanelToolbar(
        title: _name,
        accountCount: _accounts.length,
        helpText:
            '$_name 多账号保存与自动签到。授权后在本机私有目录明文保存；应用启动时恢复，运行期间自动检查。' +
            ' 自动检查：启动后约 30 秒，之后每 15 分钟；关闭应用后停止。',
        actions: [
          FilledButton(
            key: const Key('minimax-login'),
            onPressed: !_busy && _service != null && !_service!.loginPending
                ? _authorize
                : null,
            child: Text('授权 $_name 账号'),
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : _service == null && _available
                ? _restore
                : () => _run(_refresh),
            child: const Text('刷新已保存账号'),
          ),
          if (_service?.loginPending ?? false)
            TextButton(
              onPressed: () => setState(() {
                _service!.cancelAuthorization();
                _message = '已取消本次等待。';
              }),
              child: const Text('取消授权'),
            ),
        ],
      ),
      if (_service?.loginPending ?? false) ...[
        const Text('请在官方网页完成登录，LoongPass 会自动读取授权结果。'),
        if (_service?.loginCode case final String code) Text('官网验证码：$code'),
      ],
      if (!_available) const Text('账号授权目前仅支持 macOS。'),
      if (_busy) const LinearProgressIndicator(),
      if (_message != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(_message!),
        ),
      CompactAccountsTable(
        entries: [
          for (final a in _accounts)
            AccountTableEntry(
              id: a.id,
              label: a.label,
              identity: a.uid,
              balance: creditBalance(_service!.credits(a.id)),
              credits: _service!.credits(a.id),
              status: _status(a),
              receipt: a.latestClaim,
              needsAttention: {'unknown', 'needsLogin'}.contains(a.status),
              notice: _message,
              details: _details(a),
            ),
        ],
      ),
    ],
  );
}
