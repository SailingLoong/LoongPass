import 'native_account_gate.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'mac_minimax_accounts.dart';
import 'minimax_accounts.dart';

/// One owner. No service or account access until an explicit action.
class MiniMaxAccountsPanel extends StatefulWidget {
  const MiniMaxAccountsPanel({super.key, this.open});
  final Future<MiniMaxAccounts> Function()? open;
  @override
  State<MiniMaxAccountsPanel> createState() => _MiniMaxAccountsPanelState();
}

class _MiniMaxAccountsPanelState extends State<MiniMaxAccountsPanel> {
  static const _channel = MethodChannel('com.sailingloong.loongpass/files');
  MiniMaxAccounts? _service;
  List<MiniMaxAccount> _accounts = [];
  String _region = 'cn';
  String? _message;
  bool _busy = false, _automaticDirty = false;
  int _uiEpoch = 0;
  bool get _available => widget.open != null || (nativeAccountAdaptersValidated && defaultTargetPlatform == TargetPlatform.macOS);

  Future<MiniMaxAccounts> _owner() async {
    final existing = _service;
    if (existing != null) return existing;
    final opened = widget.open != null
        ? await widget.open!()
        : await openMacMiniMaxAccounts(onAutomaticFinished: _refreshAutomatic);
    if (!mounted) { opened.dispose(); throw const MiniMaxAccountError('Closed'); }
    _service = opened;
    return opened;
  }

  Future<bool> _confirm(String title, String text, String action) async =>
      await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: Text(title), content: Text(text), actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
        ],
      )) == true;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() { _busy = true; _message = null; _uiEpoch++; });
    try { await action(); }
    catch (_) { if (mounted) setState(() => _message = '操作未完成。请核对凭据、网络和本机存储；不自动重试。'); }
    finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_automaticDirty) await _refreshAutomatic();
      }
    }
  }

  Future<void> _reload(MiniMaxAccounts service) async {
    final epoch = _uiEpoch;
    final accounts = await service.list();
    if (mounted && epoch == _uiEpoch) setState(() => _accounts = accounts);
  }

  Future<void> _refreshAutomatic() async {
    if (!mounted) return;
    if (_busy) { _automaticDirty = true; return; }
    _automaticDirty = false;
    final service = _service;
    if (service == null) return;
    final epoch = _uiEpoch;
    try { await _reload(service); }
    catch (_) {
      if (mounted && epoch == _uiEpoch) setState(() => _message = '自动检查已结束，但无法刷新本机记录；请重新加载核对。');
    }
  }

  Future<void> _import() => _run(() async {
    final region = _region;
    final allowed = await _confirm('验证 MiniMax 账号',
      '读取你选择的 MiniMax 凭据文件，将其中的访问令牌发送至${region == 'cn' ? '中国区' : '国际区'} MiniMax 官方接口验证身份。此次验证不保存凭据、不签到。', '选择文件并验证');
    if (!allowed || !mounted) return;
    var selected = false;
    try {
      final path = await _channel.invokeMethod<String>('chooseMiniMaxImportSource');
      if (path == null) return;
      selected = true;
      if (!mounted) return;
      final service = await _owner();
      final verified = await service.verifyFile(path, region: region, confirmed: allowed);
      if (!mounted) return;
      final save = await _confirm('保存已验证账号',
        '账号：${verified.label}\nUID：${verified.uid}\n将访问令牌保存到 LoongPass 自己的 macOS 钥匙串，用于后续签到。不会切换 MiniMax 桌面账号。自动签到默认关闭。', '保存到钥匙串');
      if (!save || !mounted) return;
      await service.save(verified, confirmed: save);
      await _reload(service);
      if (mounted) setState(() => _message = '已保存验证过的账号。尚未执行签到。');
    } finally {
      if (selected) await _channel.invokeMethod<void>('releaseSelectedSource');
    }
  });

  Future<void> _automatic(MiniMaxAccount account, bool enabled) => _run(() async {
    if (enabled && !await _confirm('开启自动签到',
      '为 ${account.label} 开启自动签到，仅在 LoongPass 运行且账号已加载时执行。启动约 30 秒后检查，此后每 15 分钟检查；结果未知不重复发送。', '开启')) return;
    if (!mounted) return;
    final service = await _owner();
    await service.setAutomatic(account.id, enabled);
    if (enabled) service.startAutomatic();
    await _reload(service);
  });

  String _status(MiniMaxAccount a) => switch (a.status) {
    'claimed' => '最近回执：服务端返回已签到${a.points == null ? '' : '，回执积分 ${a.points}'}',
    'alreadyClaimed' => '最近回执：该周期已签到',
    'unknown' => '结果未知，不重复签到',
    'needsLogin' => '需要重新登录并导入',
    'claimable' => '上次核对可签到，执行前会重新核对',
    _ => '尚未核对签到状态',
  };

  @override
  void dispose() { _service?.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('已接入候选接口，尚未完成 Mac 与真实账号验收。桌面凭证切换尚未实现。'),
    const SizedBox(height: 12),
    Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      DropdownButton<String>(value: _region, onChanged: _busy ? null : (value) => setState(() => _region = value!),
        items: const [DropdownMenuItem(value: 'cn', child: Text('中国区')), DropdownMenuItem(value: 'global', child: Text('国际区'))]),
      FilledButton(key: const Key('minimax-import'), onPressed: !_busy && _available ? _import : null, child: const Text('导入并验证')),
      OutlinedButton(onPressed: !_busy && _available ? () => _run(() async { final service = await _owner(); await _reload(service); service.startAutomatic(); }) : null, child: const Text('加载已保存账号')),
    ]),
    const Text('选择真实的 prod/cn/mcode-public/auth.json（中国区）或 prod/en/mcode-public/auth.json（国际区），不扫描其他文件。'),
    const Text('加载后将恢复这些账号已保存的自动签到设置；关闭应用后停止。列表显示最近一次读取的记录，可重新加载刷新。'),
    if (!_available) const Text('原生验收未完成，真实账号操作暂不可用；需先完成 Mac 编译与隔离钥匙串验证。'),
    if (_busy) const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
    if (_message != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(_message!)),
    for (final account in _accounts) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(account.label, style: const TextStyle(fontWeight: FontWeight.w600)),
      Text('${account.region == 'cn' ? '中国区' : '国际区'} · ${account.uid}'),
      Text(_status(account)),
      Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
        OutlinedButton(onPressed: _busy || account.status == 'unknown' ? null : () => _run(() async {
          final service = await _owner(); await service.claim(account.id); await _reload(service);
        }), child: const Text('签到')),
        Row(mainAxisSize: MainAxisSize.min, children: [const Text('自动签到'), Switch(value: account.automatic, onChanged: _busy ? null : (value) => _automatic(account, value))]),
      ]),
    ]))),
  ]);
}
