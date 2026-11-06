import 'compact_accounts_table.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'credit_summary_view.dart';
import 'mac_account_document_store.dart';
import 'trae_accounts.dart';
import 'trae_http.dart';

class TraeAccountsPanel extends StatefulWidget {
  const TraeAccountsPanel({super.key, this.create});
  final TraeAccounts Function()? create;
  @override
  State<TraeAccountsPanel> createState() => _TraeAccountsPanelState();
}

class _TraeAccountsPanelState extends State<TraeAccountsPanel> {
  static const _channel = MethodChannel('com.sailingloong.loongpass/files');
  TraeAccounts? _owner;
  List<TraeAccount> _accounts = [];
  bool _busy = false;
  String? _message;
  @override
  void initState() {
    super.initState();
    if (widget.create != null || defaultTargetPlatform == TargetPlatform.macOS)
      unawaited(_restore());
  }

  Future<void> _restore() => _run(() async {
    _owner ??=
        widget.create?.call() ??
        TraeAccounts(
          store: MacAccountDocumentStore('TRAE-cn'),
          http: TraeHttp(),
          proof: (privateKey, refresh) async {
            final result = await _channel.invokeMapMethod<String, dynamic>(
              'signTraeRefresh',
              {'privateKeyPEM': privateKey, 'refreshToken': refresh},
            );
            if (result == null) throw const TraeFailure('device_unavailable');
            return result;
          },
        );
    _owner!.onChanged = _reload;
    await _reload();
    _owner!.startAutomatic();
  });
  Future<void> _reload() async {
    final values = await _owner!.accounts();
    if (mounted)
      setState(() {
        _accounts = values;
        _message = _owner!.message ?? _message;
      });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on TraeFailure catch (e) {
      if (mounted)
        setState(
          () => _message = switch (e.code) {
            'device_required' => '请先读取本机 TRAE CN 当前登录，以复用真实设备身份。',
            'authorization_expired' =>
              '此授权已到期；可重新读取当前客户端登录，或通过 LoongPass 官网授权保存独立账号。',
            _ => '操作未完成（${e.code}），未确认的签到不会重复发送。',
          },
        );
    } catch (_) {
      if (mounted) setState(() => _message = '无法读取当前授权。请确认所选文件来自已登录的 TRAE CN。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() => _run(() async {
    Map<String, dynamic>? source;
    if (!_owner!.importPending) {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'chooseTraeAuthorization',
      );
      if (raw == null) return;
      source = raw.map(
        (key, value) => MapEntry(
          key,
          value is Map ? Map<String, dynamic>.from(value) : value,
        ),
      );
    }
    await _owner!.importCurrent(source);
    await _reload();
  });
  Future<void> _login() => _run(() async {
    final url = await _owner!.beginAuthorization();
    await _channel.invokeMethod<void>('openTraeAuthorization', {
      'url': url.toString(),
    });
    _owner!.followAuthorization();
    if (mounted) setState(() => _message = '请在 TRAE CN 官网完成授权，正在自动等待结果。');
  });
  String _outcome(TraeAccount a) => switch (a.outcome) {
    'claimed' =>
      a.credited == null ? '已核对官方签到状态。' : '已核对签到，本次余额净增加 ${a.credited} 积分。',
    'observedClaimed' => '官方显示今日已签到，本次没有重复领取。',
    'unknown' => '领取结果待核对，同一日期不会重复发送。',
    'ineligible' => '当前账号暂无可领取的签到奖励。',
    _ => '等待签到检查。',
  };
  @override
  void dispose() {
    _owner?.dispose();
    super.dispose();
  }

  Widget _details(TraeAccount a) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(a.label, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(a.uid),
          Text(_outcome(a)),
          if (a.authorizationOwner == 'officialClient')
            const Text('复用客户端当前授权；到期后需重新读取或独立官网授权。'),
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
                        : (v) => _run(() async {
                            await _owner!.setAutomatic(a.uid, v);
                            await _reload();
                          }),
                  ),
                ],
              ),
            ],
          ),
          if (_owner!.credits(a.uid) case final credits?)
            CreditSummaryView(summary: credits),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      AccountPanelToolbar(
        title: 'TRAE CN',
        accountCount: _accounts.length,
        helpText:
            'TRAE CN 账号保存、自动签到与积分到期。仅接入已确认有签到奖励的国内版。授权以明文保存在本机私有目录。' +
            ' 启动约 30 秒后检查，之后每 15 分钟；关闭应用后停止。',
        actions: [
          FilledButton(
            key: const Key('trae-import'),
            onPressed: _busy || _owner == null || _owner!.loginPending
                ? null
                : _import,
            child: Text(
              _owner?.importPending == true ? '重试保存当前授权' : '读取 TRAE CN 当前登录',
            ),
          ),
          OutlinedButton(
            key: const Key('trae-login'),
            onPressed: _busy || _owner == null || _owner!.loginPending
                ? null
                : _login,
            child: const Text('官网授权其他账号'),
          ),
          if (_owner?.loginPending == true)
            TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      _owner!.cancelAuthorization();
                      setState(() => _message = '授权已取消。');
                    },
              child: const Text('取消授权'),
            ),
        ],
      ),
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
              balance: creditBalance(_owner!.credits(a.uid)),
              credits: _owner!.credits(a.uid),
              status: _outcome(a),
              receipt: a.latestClaim,
              needsAttention: a.outcome == 'unknown',
              notice: _message,
              details: _details(a),
            ),
        ],
      ),
    ],
  );
}
