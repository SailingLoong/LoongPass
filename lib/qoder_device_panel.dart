import 'compact_accounts_table.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'qoder_device_accounts.dart';
import 'qoder_device_flutter.dart';
import 'credit_summary_view.dart';

class QoderDeviceAccountsPanel extends StatefulWidget {
  const QoderDeviceAccountsPanel({
    super.key,
    this.region = QoderRegion.cn,
    this.create,
  });
  final QoderRegion region;
  final QoderDeviceAccounts Function()? create;
  @override
  State<QoderDeviceAccountsPanel> createState() =>
      _QoderDeviceAccountsPanelState();
}

class _QoderDeviceAccountsPanelState extends State<QoderDeviceAccountsPanel> {
  static const _channel = MethodChannel('com.sailingloong.loongpass/files');
  QoderDeviceAccounts? _owner;
  List<QoderSavedAccount> _accounts = [];
  bool _busy = false;
  String? _message;
  bool get _available =>
      widget.create != null || defaultTargetPlatform == TargetPlatform.macOS;
  @override
  void initState() {
    super.initState();
    if (_available) unawaited(_restore());
  }

  Future<void> _restore() => _run(() async {
    final owner = _owner ??=
        widget.create?.call() ??
        createQoderDeviceAccounts(region: widget.region);
    owner.onChanged = _reload;
    await _reload();
    owner.startAutomatic();
  });
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on QoderAccountError catch (e) {
      if (mounted) setState(() => _message = '操作未完成（${e.code}）；未确认的领取不会重复发送。');
    } catch (_) {
      if (mounted) setState(() => _message = '操作未完成，请核对网络和本机记录。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reload() async {
    final owner = _owner;
    if (owner == null) return;
    final accounts = await owner.accountViews();
    if (mounted)
      setState(() {
        _accounts = accounts;
        _message = owner.message ?? _message;
      });
  }

  Future<void> _start() => _run(() async {
    final grant = await _owner!.startLogin();
    if (!mounted) {
      await _owner!.cancelLogin();
      return;
    }
    await _channel.invokeMethod<void>('openQoderAuthorization', {
      'url': grant.url.toString(),
      'region': widget.region.name,
    });
    _owner!.followAuthorization();
    setState(() => _message = '请在官网完成授权，正在自动等待结果。');
  });
  Future<void> _cancel() => _run(() async {
    final result = await _owner!.cancelLogin();
    if (mounted)
      setState(
        () => _message = switch (result) {
          'completed' => '授权已先完成保存，请核对账号。',
          'cancelled' => '本次授权已取消。',
          _ => '保存结果未知，不能确认取消，请核对已保存账号。',
        },
      );
    await _reload();
  });
  String _outcome(String? state) => switch (state) {
    'claimedDeltaUnknown' => '服务端返回领取成功，当前余额增量尚未核实。',
    'observedClaimed' => '服务端显示已领取，本次没有重复发送。',
    'unknown' => '领取结果未知，停止重复发送。',
    'unavailable' => '当前没有已确认可领取的免费活动。',
    _ => '等待签到检查。',
  };
  @override
  void dispose() {
    _owner?.dispose();
    super.dispose();
  }

  Widget _details(QoderSavedAccount a) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(a.label, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(a.uid),
          Text(_outcome(a.outcome)),
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await _owner!.claim(a.uid);
                        await _reload();
                      }),
                child: const Text('核对并签到'),
              ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await _owner!.refreshCredits(a.uid);
                        await _reload();
                      }),
                child: const Text('查询积分与到期'),
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
                            await _owner!.setAutomatic(a.uid, enabled);
                            await _reload();
                          }),
                  ),
                ],
              ),
            ],
          ),
          if (_owner!.credits(a.uid) case final credits?) ...[
            if (credits.planRemaining case final remaining?)
              Text('套餐剩余：$remaining'),
            if (credits.addOnRemaining case final remaining?)
              Text('附加积分剩余：$remaining'),
            const Text('以下仅为官方返回的专属积分包；与汇总可能重叠，其他积分的到期明细尚未提供。'),
            CreditSummaryView(summary: credits.packages),
          ],
        ],
      ),
    ),
  );

  String _balance(String uid) {
    final c = _owner!.credits(uid);
    if (c == null) return '尚未查询';
    return '套餐 ${c.planRemaining == null ? '未知' : accountPoints(c.planRemaining!)} / 附加 ${c.addOnRemaining == null ? '未知' : accountPoints(c.addOnRemaining!)} 积分';
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      AccountPanelHelp(
        text:
            '${widget.region.label} 多账号保存与自动签到。授权后明文保存在本机私有目录，启动时恢复账号；国内外账号相互独立。',
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          FilledButton(
            key: const Key('qoder-login'),
            onPressed: !_busy && _owner != null && !_owner!.loginPending
                ? _start
                : null,
            child: Text('授权 ${widget.region.label} 账号'),
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : _owner == null && _available
                ? _restore
                : () => _run(_reload),
            child: const Text('刷新已保存账号'),
          ),
          if (_owner?.loginPending ?? false)
            TextButton(
              onPressed: _busy ? null : _cancel,
              child: const Text('取消授权'),
            ),
        ],
      ),
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
              id: a.uid,
              label: a.label,
              identity: a.uid,
              balance: _balance(a.uid),
              credits: _owner!.credits(a.uid)?.packages,
              status: _outcome(a.outcome),
              latestClaim: a.latestClaim?.display ?? '暂无已确认记录',
              needsAttention: a.outcome == 'unknown',
              notice: _message,
              details: _details(a),
            ),
        ],
      ),
      const Text('自动检查：启动约 30 秒后，之后每 15 分钟；关闭应用后停止。'),
    ],
  );
}
