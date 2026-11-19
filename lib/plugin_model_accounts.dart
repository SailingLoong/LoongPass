import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'managed_app.dart';
import 'plugin_accounts.dart';
import 'plugin_credit_balance.dart';
import 'plugin_model_catalog.dart';
import 'workspace_tools.dart' show WorkspaceCard;

String modelSourceName(String provider) {
  final app = ManagedApp.values
      .where((a) => a.nativeProviders.contains(provider))
      .firstOrNull;
  return app == null ? provider : '${app.label} · ${app.region}';
}

String modelExpiryText(PluginModelBinding binding) {
  final expiry = binding.expiry;
  if (expiry == null) return '额度到期时间未知';
  final at = expiry.at.toLocal().toString().substring(0, 16);
  final amount = expiry.amount;
  return '${amount == null ? '' : '${amount.amount} ${amount.unit} · '}$at 到期';
}

String _remaining(PluginModelBinding binding) {
  final values = <String>[];
  final windows = binding.quota.windows
      .where((w) => w['aside'] != true)
      .toList();
  for (final window in windows) {
    final amount = pluginWindowRemaining(window);
    final name = windows.length > 1 ? '${window['name'] ?? '额度'} ' : '';
    if (amount != null) {
      values.add('$name$amount ${pluginWindowBalance(window)?.unit ?? '单位未知'}');
    } else if (window['used'] is num) {
      values.add('${name}已用 ${window['used']}%');
    }
  }
  return values.isEmpty ? '未知' : values.join('\n');
}

class PluginModelAccounts extends StatefulWidget {
  const PluginModelAccounts({
    super.key,
    required this.model,
    required this.busy,
    required this.onEnable,
    required this.onAuthorize,
    this.onOpenAccount,
  });
  final PluginModel model;
  final bool busy;
  final void Function(String, bool) onEnable;
  final void Function(String, bool) onAuthorize;
  final ValueChanged<PluginAccount>? onOpenAccount;
  @override
  State<PluginModelAccounts> createState() => _PluginModelAccountsState();
}

class _PluginModelAccountsState extends State<PluginModelAccounts> {
  final _expanded = <String>{};
  @override
  Widget build(BuildContext context) => WorkspaceCard(
    child: LayoutBuilder(
      builder: (context, box) {
        final wide =
            box.maxWidth >=
            660 * MediaQuery.textScalerOf(context).scale(14) / 14;
        final keys = widget.model.bindings.map((b) => b.account.key).toSet();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide)
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Expanded(flex: 3, child: Text('账号 / 渠道')),
                    Expanded(flex: 2, child: Text('适用剩余额度')),
                    Expanded(flex: 3, child: Text('最近到期批次')),
                    Expanded(flex: 2, child: Text('路由状态')),
                    SizedBox(width: 52, child: Text('参与')),
                  ],
                ),
              ),
            for (final key in keys)
              _account(
                context,
                widget.model.bindings
                    .where((b) => b.account.key == key)
                    .toList(),
                wide,
              ),
          ],
        );
      },
    ),
  );

  Widget _account(
    BuildContext context,
    List<PluginModelBinding> bindings,
    bool wide,
  ) {
    final binding = bindings.first, account = binding.account;
    final muted = context.theme.typography.body.xs.copyWith(
      color: context.theme.colors.mutedForeground,
    );
    final status = !widget.model.enabled
        ? '模型停用'
        : binding.grant.authorizationRequired
        ? '需要授权'
        : !binding.grant.enabled
        ? '尚未授权'
        : !binding.enabled
        ? '已停用'
        : switch (binding.status) {
            ModelQuotaStatus.exhausted => '额度耗尽',
            ModelQuotaStatus.expired => '额度已过期',
            _ =>
              widget.model.preferred?.account.key == account.key
                  ? '新会话首选'
                  : '候选可用',
          };
    final name = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FButton(
          variant: FButtonVariant.ghost,
          size: FButtonSizeVariant.sm,
          mainAxisSize: MainAxisSize.min,
          onPress: widget.onOpenAccount == null
              ? null
              : () => widget.onOpenAccount!(account),
          child: Flexible(child: Text(account.label, softWrap: true)),
        ),
        Text(modelSourceName(account.provider), style: muted),
      ],
    );
    final toggle = FSwitch(
      key: ValueKey('model-account-${account.key}'),
      semanticsLabel: '参与此模型路由 ${account.label}',
      value: binding.grant.enabled && binding.enabled,
      enabled:
          !widget.busy &&
          !binding.grant.authorizationRequired &&
          binding.grant.enabled,
      onChange: (value) => widget.onEnable(account.key, value),
    );
    final expiry = binding.expiry;
    final expiringAmount = expiry?.amount;
    final expiryLabel = expiry == null
        ? '未知'
        : expiry.at.toLocal().toString().substring(0, 16);
    final expiryCell = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(expiryLabel),
        if (expiringAmount != null)
          Text('${expiringAmount.amount} ${expiringAmount.unit}', style: muted),
      ],
    );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.theme.colors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(flex: 3, child: name),
                Expanded(flex: 2, child: Text(_remaining(binding))),
                Expanded(flex: 3, child: expiryCell),
                Expanded(flex: 2, child: Text(status, style: muted)),
                SizedBox(width: 52, child: toggle),
              ],
            )
          else ...[
            Row(
              children: [
                Expanded(child: name),
                const SizedBox(width: 8),
                toggle,
              ],
            ),
            const SizedBox(height: 6),
            Text('剩余额度 ${_remaining(binding)}'),
            Text(modelExpiryText(binding), style: muted),
            Text(status, style: muted),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: FButton(
              variant: FButtonVariant.ghost,
              size: FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              onPress: () => setState(() {
                _expanded.contains(account.key)
                    ? _expanded.remove(account.key)
                    : _expanded.add(account.key);
              }),
              child: Text(_expanded.contains(account.key) ? '收起来源' : '来源与额度详情'),
            ),
          ),
          if (_expanded.contains(account.key)) ...[
            if (account.provider == 'zcode')
              for (final giftOnly in bindings.map((b) => b.giftOnly).toSet())
                Text(giftOnly ? '仅赠送' : '赠送优先，可转套餐', style: muted),
            Text(
              account.queriedAt == null
                  ? '额度尚无成功查询记录'
                  : '额度查询于 ${account.queriedAt!.toLocal().toString().substring(0, 16)}',
              style: muted,
            ),
          ],
          if (!binding.grant.enabled && !binding.grant.authorizationRequired)
            FSwitch(
              value: false,
              enabled: !widget.busy,
              leadingLabel: true,
              label: const Text('授权此账号用于模型服务'),
              description: const Text('开启后，此账号的已启用模型可参与路由'),
              onChange: (value) => widget.onAuthorize(account.key, value),
            ),
        ],
      ),
    );
  }
}
