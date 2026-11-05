import 'native_account_gate.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'qoder_cn.dart';
import 'qoder_cn_flutter.dart';

class QoderCnPanel extends StatefulWidget {
  const QoderCnPanel({super.key, this.create});
  final QoderCn Function()? create;
  @override State<QoderCnPanel> createState() => _QoderCnPanelState();
}
class _QoderCnPanelState extends State<QoderCnPanel> {
  static const _channel = MethodChannel('com.sailingloong.loongpass/files');
  QoderCn? _owner;
  List<String> _accounts = [];
  bool _busy = false, _login = false;
  String? _message;
  QoderCn get _service => _owner ??= (widget.create ?? createQoderCn)();
  bool get _available => widget.create != null || (nativeAccountAdaptersValidated && defaultTargetPlatform == TargetPlatform.macOS);

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() { _busy = true; _message = null; });
    try { await action(); }
    catch (_) { if (mounted) setState(() => _message = '操作未完成，保存或领取结果可能未知；请核对账号记录，不自动重试。'); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  Future<void> _reload() async {
    final accounts = await _service.accounts();
    if (mounted) setState(() => _accounts = accounts);
  }
  Future<void> _start() => _run(() async {
    final allowed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('授权 Qoder 中国区账号'),
      content: const Text('将在 Qoder 官方网页由你授权，并将得到的凭据保存到 LoongPass 自己的 macOS 钥匙串，用于后续主动签到。此操作建立持久访问，不会自动签到或切换桌面账号。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('授权并保存')),
      ],
    ));
    if (allowed != true || !mounted) return;
    final grant = await _service.startLogin();
    if (!mounted) { await _service.cancelLogin(); return; }
    setState(() => _login = true);
    try {
      await _channel.invokeMethod<void>('openQoderCnAuthorization', {'url': grant.url.toString()});
      if (mounted) setState(() => _message = '请在官方网页完成授权，再点“检查授权结果”。有效期约 5 分钟。');
    } catch (_) {
      final outcome = await _service.cancelLogin();
      if (mounted) setState(() { _login = false; _message = outcome == 'cancelled' ? '无法打开授权页面，本次授权已取消。' : '无法打开授权页面，授权保存状态未确认，请加载账号核对。'; });
    }
  });
  Future<void> _poll() => _run(() async {
    try {
      final uid = await _service.pollLogin();
      if (!mounted) return;
      if (uid == null) { setState(() => _message = '尚未完成官方授权。'); return; }
      setState(() { _login = false; _message = '授权账号已保存，未执行签到。'; });
      await _reload();
    } catch (_) {
      final outcome = await _service.cancelLogin();
      if (mounted) setState(() { _login = false; _message = switch (outcome) {
        'completed' => '授权已保存，请加载账号核对。',
        'cancelled' => '授权未完成或已过期，请重新发起。',
        _ => '授权保存结果未知，请加载账号核对。',
      }; });
    }
  });
  Future<void> _cancel() => _run(() async {
    final outcome = await _service.cancelLogin();
    if (!mounted) return;
    setState(() { _login = false; _message = switch (outcome) {
      'cancelled' => '本次授权已取消。',
      'completed' => '授权已先完成保存，未撤销，请加载账号核对。',
      _ => '授权保存结果未知，不能确认取消，请加载账号核对。',
    }; });
  });
  String _outcome(Object? value) => switch (value) {
    'claimedDeltaUnknown' => '收到领取回执，实际额度增量尚未核实',
    'observedClaimed' => '服务端显示已领取，本次未重复领取',
    'unknown' => '结果未知，不重复领取',
    _ => '当前活动不满足领取条件，未发送领取',
  };
  @override void dispose() {
    final owner = _owner;
    if (owner != null) unawaited(owner.cancelLogin().then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    super.dispose();
  }
  @override Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Qoder 中国区独立授权 · 待 Mac 与真实账号验收。不切换 Qoder 桌面账号，不自动签到；凭据过期需重新授权。'),
    const SizedBox(height: 12),
    Wrap(spacing: 12, runSpacing: 8, children: [
      FilledButton(key: const Key('qoder-cn-login'), onPressed: !_busy && !_login && _available ? _start : null, child: const Text('授权中国区账号')),
      OutlinedButton(onPressed: !_busy && !_login && _available ? () => _run(_reload) : null, child: const Text('加载已保存账号')),
      if (_login) OutlinedButton(onPressed: _busy ? null : _poll, child: const Text('检查授权结果')),
      if (_login) TextButton(onPressed: _busy ? null : _cancel, child: const Text('取消授权')),
    ]),
    if (!_available) const Text('原生验收未完成，真实账号操作暂不可用；需先完成 Mac 编译与隔离钥匙串验证。'),
    if (_busy) const LinearProgressIndicator(),
    if (_message != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(_message!)),
    for (final uid in _accounts) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(uid),
      OutlinedButton(onPressed: _busy || _login ? null : () => _run(() async {
        final results = await _service.claim(uid);
        if (mounted) setState(() => _message = results.isEmpty ? '没有可领取活动。' : results.map((r) => _outcome(r['outcome'])).join('\n'));
      }), child: const Text('核对并签到')),
    ]))),
  ]);
}
