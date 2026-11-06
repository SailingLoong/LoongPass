import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'mac_account_document_store.dart';
import 'zcode_activity_accounts.dart';
import 'zcode_api.dart';

class ZcodeAccountsPanel extends StatefulWidget {
  const ZcodeAccountsPanel({super.key, this.create});
  final ZcodeActivityAccounts Function()? create;
  @override
  State<ZcodeAccountsPanel> createState() => _ZcodeAccountsPanelState();
}

class _ZcodeAccountsPanelState extends State<ZcodeAccountsPanel> {
  static const _channel = MethodChannel('com.sailingloong.loongpass/files');
  ZcodeActivityAccounts? _owner;
  List<ZcodeActivityAccount> _accounts = [];
  bool _busy = false;
  int _availableDevices = 0;
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
        ZcodeActivityAccounts(
          store: MacAccountDocumentStore('ZCode'),
          api: ZcodeApi(ZcodeHttp()),
        );
    _owner!.onChanged = _reload;
    await _reload();
    _owner!.startAutomatic();
  });
  Future<void> _reload() async {
    final values = await _owner!.accounts();
    final available = await _owner!.availableDeviceCount();
    if (mounted)
      setState(() {
        _accounts = values;
        _availableDevices = available;
        _message = _owner!.authorizationError == null
            ? _owner!.message ?? _message
            : _failureMessage(_owner!.authorizationError!);
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
    } on ZcodeFailure catch (e) {
      if (mounted) setState(() => _message = _failureMessage(e.code));
    } catch (_) {
      if (mounted)
        setState(() => _message = '无法读取设备信息或打开官方授权页面。请确认本机已安装并使用过 ZCode。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _failureMessage(String code) => switch (code) {
    'device_required' => '未找到本机 ZCode 的已有设备信息。请安装并打开一次官方客户端后重试。',
    'device_in_use' => '这个设备号已被账号使用，请使用其他已有设备重新绑定。',
    'device_pool_empty' => '没有可分配的已有设备号，原账号未改变。',
    'account_mismatch' => '授权返回了其他账号，未更换任何已保存账号。请登录所选账号后重试。',
    'binding_changed' => '账号设备已被其他操作更新，本次授权未覆盖它。',
    'device_rebind_required' => '该账号已保存。请从该账号的“重新授权”或“重新绑定设备”继续。',
    _ => '操作未完成（$code）。未确认的领取会保留记录。',
  };

  Future<void> _login({
    ZcodeActivityAccount? account,
    bool replaceDevice = false,
  }) => _run(() async {
    final context = await _channel.invokeMapMethod<String, dynamic>(
      'zcodeRequestContext',
    );
    if (context == null) throw const ZcodeFailure('device_required');
    final url = await _owner!.beginAuthorization(
      'bigmodel',
      context,
      accountId: account?.id,
      replaceDevice: replaceDevice,
    );
    try {
      await _channel.invokeMethod<void>('openZcodeAuthorization', {
        'url': url.toString(),
      });
      _owner!.followAuthorization();
    } catch (_) {
      _owner!.cancelAuthorization();
      rethrow;
    }
    await _reload();
  });
  Future<String?> _verify(ZcodeCaptchaConfig config) async {
    try {
      return await _channel.invokeMethod<String>(
        'verifyZcodeClaim',
        config.values,
      );
    } catch (_) {
      throw const ZcodeFailure('verification_unavailable');
    }
  }

  String _status(String status) => switch (status) {
    'claimable' => '当前有可领取活动，尚未领取。',
    'claimed' => '已核对官方活动权益到账。',
    'observedClaimed' => '已有该活动权益，本次没有重复领取。',
    'noOffer' => '服务端当前没有可领取活动。',
    'discoveryIncomplete' => '部分活动信息暂不可用，尚不能确认是否有其他可领取奖励。',
    'pending' => '领取结果待核对；只查询回执，不会重复发送。',
    'verificationRequired' => '需要验证码，自动领取已暂停。点击“核对并领取活动”完成验证。',
    'activationRequired' => '活动要求先使用官方 ZCode 客户端，自动领取已暂停。',
    'ineligible' => '服务端确认本次不符合活动领取条件。',
    'authorization_required' => '授权已失效，请通过官网重新授权此账号。',
    _ => '等待检查活动与额度。',
  };
  String _time(int seconds) => DateTime.fromMillisecondsSinceEpoch(
    seconds * 1000,
  ).toLocal().toString().split('.').first;
  @override
  void dispose() {
    _owner?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('ZCode · 智谱 BigModel。保存多个账号，自动检查并领取官方开放的活动奖励。活动以服务端资格为准。'),
      const SizedBox(height: 8),
      const Text('授权以明文保存在本机私有目录。运行期间每 10 分钟检查活动，退出应用即停止。'),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          FilledButton(
            key: const Key('zcode-login'),
            onPressed: _busy || _owner == null || _owner!.loginPending
                ? null
                : _login,
            child: const Text('授权智谱 BigModel 账号'),
          ),
          if (_owner?.loginPending == true)
            TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      final cancelled = _owner!.cancelAuthorization();
                      setState(
                        () => _message = cancelled ? '授权已取消。' : '保存已开始，正在核对结果。',
                      );
                    },
              child: const Text('取消授权'),
            ),
          TextButton(
            onPressed: _busy ? null : _restore,
            child: const Text('恢复已保存账号'),
          ),
        ],
      ),
      if (_busy) const LinearProgressIndicator(),
      if (_availableDevices > 0) Text('已有设备池：$_availableDevices 个可分配设备号'),
      if (_message != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(_message!),
        ),
      for (final a in _accounts)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  a.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  '${a.family == 'bigmodel' ? '智谱 BigModel' : 'Z.AI'} · ${a.uid}',
                ),
                Text(_status(a.status)),
                Text('设备号尾号 ${a.deviceSuffix}'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      key: ValueKey('zcode-inspect-${a.id}'),
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              await _owner!.inspect(a.id);
                              await _reload();
                            }),
                      child: const Text('检查活动与额度'),
                    ),
                    OutlinedButton(
                      key: ValueKey('zcode-claim-${a.id}'),
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              await _owner!.claim(a.id, verify: _verify);
                              await _reload();
                            }),
                      child: const Text('核对并领取活动'),
                    ),
                    TextButton(
                      onPressed: _busy || _owner!.loginPending
                          ? null
                          : () => _login(account: a),
                      child: const Text('重新授权'),
                    ),
                    TextButton(
                      onPressed:
                          _busy ||
                              _owner!.loginPending ||
                              _availableDevices == 0
                          ? null
                          : () => _login(account: a, replaceDevice: true),
                      child: const Text('重新绑定设备'),
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('自动领取活动'),
                  value: a.automatic,
                  onChanged: _busy
                      ? null
                      : (v) => _run(() async {
                          await _owner!.setAutomatic(a.id, v);
                          await _reload();
                        }),
                ),
                if (a.checkedAt != null)
                  Text('最近核对：${_time(a.checkedAt! ~/ 1000)}'),
                if (a.buckets.isEmpty) const Text('尚无已核实的可用额度明细。'),
                for (final b in a.buckets)
                  Text(
                    '${b.label}：剩余 ${b.remaining ?? '未知'} ${b.unit}；'
                    '${b.expiresAt == null ? '到期时间未知' : '${_time(b.expiresAt!)} 到期'}',
                  ),
              ],
            ),
          ),
        ),
    ],
  );
}
