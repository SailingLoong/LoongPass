import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../compact_accounts_table.dart';
import '../credit_summary_view.dart';
import 'reward_provider.dart';
import 'reward_accounts.dart';

class RewardAccountsPanel extends StatefulWidget {
  const RewardAccountsPanel({
    super.key,
    required this.provider,
    required this.owner,
    this.enabled = true,
  });
  final RewardProvider provider;
  final RewardAccounts owner;
  final bool enabled;
  @override
  State<RewardAccountsPanel> createState() => _RewardAccountsPanelState();
}

class _RewardAccountsPanelState extends State<RewardAccountsPanel> {
  static const _channel = MethodChannel('com.sailingloong.loongpass/files');
  final _phone = TextEditingController(), _code = TextEditingController();
  String? _message;
  RewardAccounts get owner => widget.owner;
  Future<void> _run(Future<void> Function() action) async {
    if (owner.busy) return;
    setState(() => _message = null);
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _message = '操作未完成。请核对官方授权后重试；待核对的领取不会重复发送。');
    }
  }

  Future<void> _login() => _run(() async {
    final url = await owner.beginLogin(
      widget.provider.id,
      phone: _phone.text.trim(),
    );
    if (url != null) {
      try {
        await _channel.invokeMethod<void>('openExternalHTTPS', {
          'url': url.toString(),
        });
      } catch (_) {
        owner.cancelLogin();
        rethrow;
      }
    }
  });
  String _status(RewardAccount account) {
    final text = switch (account.outcome) {
      'claimed' => '领取已确认',
      'already' => '官方确认今日已领',
      'unavailable' => '暂无可领取奖励',
      'unknown' => '结果待核对，不会重复领取',
      'rejected' => '领取被拒绝，可核对授权后重试',
      _ => '等待领取检查',
    };
    final attention = account.needsAttention && account.outcome != 'unknown'
        ? ' · 最近查询失败，请核对授权'
        : '';
    return '${account.day == null ? '' : '${account.day} · '}$text$attention';
  }

  Future<void> _remove(RewardAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除已保存的账号？'),
        content: const Text('将移除账号授权，保留已发送的领取记录，以免重新登录后重复领取。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted)
      await _run(() => owner.remove(account.provider, account.identity));
  }

  Widget _details(RewardAccount account) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          account.label,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        Text(_status(account)),
        if (account.credits != null)
          CreditSummaryView(summary: account.credits!),
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton(
              onPressed: owner.busy
                  ? null
                  : () => _run(
                      () => owner.claim(account.provider, account.identity),
                    ),
              child: const Text('核对并领取'),
            ),
            OutlinedButton(
              onPressed: owner.busy
                  ? null
                  : () => _run(
                      () => owner.refreshCredits(
                        account.provider,
                        account.identity,
                      ),
                    ),
              child: const Text('查询积分与到期'),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('辅助领取'),
                Switch(
                  value: account.automatic,
                  onChanged: owner.busy
                      ? null
                      : (value) => _run(
                          () => owner.setAutomatic(
                            account.provider,
                            account.identity,
                            value,
                          ),
                        ),
                ),
              ],
            ),
            TextButton(
              onPressed: owner.busy ? null : () => _remove(account),
              child: const Text('删除账号'),
            ),
          ],
        ),
      ],
    ),
  );
  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
    stream: owner.changes,
    builder: (context, _) {
      final provider = widget.provider,
          login = owner.loginProvider == provider.id;
      final sms = provider.loginKind == RewardLoginKind.sms;
      final disabled = !widget.enabled || owner.busy;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.enabled) const Text('此平台的账号保存与授权当前需要 macOS。'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (sms)
                SizedBox(
                  width: 180,
                  child: TextField(
                    controller: _phone,
                    enabled: !disabled && !login,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: '手机号'),
                  ),
                ),
              OutlinedButton(
                onPressed: disabled || owner.loginProvider != null
                    ? null
                    : _login,
                child: Text(sms ? '发送登录验证码' : '官网授权新账号'),
              ),
              if (login && sms) ...[
                SizedBox(
                  width: 130,
                  child: TextField(
                    controller: _code,
                    enabled: !disabled,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    decoration: const InputDecoration(labelText: '短信验证码'),
                  ),
                ),
                OutlinedButton(
                  onPressed: disabled
                      ? null
                      : () => _run(() async {
                          if (await owner.completeLogin(
                            verificationCode: _code.text.trim(),
                          )) {
                            _code.clear();
                            _phone.clear();
                          }
                        }),
                  child: const Text('完成登录'),
                ),
              ],
              if (login)
                TextButton(
                  onPressed: widget.enabled ? owner.cancelLogin : null,
                  child: const Text('取消授权'),
                ),
            ],
          ),
          if (owner.busy) const LinearProgressIndicator(),
          if (login) Text(sms ? '短信已发送，请填写验证码。' : '请在官网完成登录，正在等待授权结果。'),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_message!),
            ),
          if (owner.error != null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('最近操作未完成，当前显示已保存的结果；可查询官方状态后重试。'),
            ),
          CompactAccountsTable(
            entries: [
              for (final account in owner.accountsFor(provider.id))
                AccountTableEntry(
                  id: account.identity,
                  label: account.label,
                  identity: account.identity,
                  balance: creditBalance(account.credits),
                  credits: account.credits,
                  status: _status(account),
                  receipt: account.receipt,
                  needsAttention: account.needsAttention,
                  details: _details(account),
                ),
            ],
          ),
        ],
      );
    },
  );
}
