import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'managed_app.dart';
import 'model_workspace_view_model.dart';
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
    required this.vm,
    this.onOpenAccount,
  });
  final PluginModel model;
  final ModelWorkspaceViewModel vm;
  final ValueChanged<PluginAccount>? onOpenAccount;
  @override
  State<PluginModelAccounts> createState() => _PluginModelAccountsState();
}

class _PluginModelAccountsState extends State<PluginModelAccounts> {
  final _expanded = <String>{};
  // Keep the row under the pointer when an edit changes routing priority.
  late final _accountOrder = _sourceKeys;
  Set<String> get _sourceKeys => {
    for (final binding in widget.model.bindings) binding.account.key,
  };

  @override
  void didUpdateWidget(PluginModelAccounts oldWidget) {
    super.didUpdateWidget(oldWidget);
    final keys = _sourceKeys;
    _accountOrder
      ..retainAll(keys)
      ..addAll(keys);
    _expanded.retainAll(keys);
  }

  @override
  Widget build(BuildContext context) => WorkspaceCard(
    child: LayoutBuilder(
      builder: (context, box) {
        final wide =
            box.maxWidth >=
            660 * MediaQuery.textScalerOf(context).scale(14) / 14;
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
                    Expanded(
                      flex: 2,
                      child: Text('参与此模型', textAlign: TextAlign.end),
                    ),
                  ],
                ),
              ),
            for (final key in _accountOrder)
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
    final vm = widget.vm;
    final openAccount = widget.onOpenAccount == null
        ? null
        : () => widget.onOpenAccount!(account);
    final String status;
    final Widget action;
    if (binding.grant.authorizationRequired) {
      status = '平台账号需重新授权';
      action = openAccount == null
          ? const SizedBox.shrink()
          : FButton(
              variant: FButtonVariant.outline,
              size: FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              semanticsLabel: '查看账号 ${account.label}',
              onPress: openAccount,
              child: const Text('查看账号'),
            );
    } else if (!binding.grant.enabled) {
      status = '开放后，本机已启用的模型可用此账号';
      action = FButton(
        variant: FButtonVariant.outline,
        size: FButtonSizeVariant.sm,
        mainAxisSize: MainAxisSize.min,
        semanticsLabel: '向本机模型服务开放 ${account.label}',
        onPress: vm.busy ? null : () => vm.authorize(account.key, true),
        child: const Text('开放账号'),
      );
    } else {
      status = !widget.model.published
          ? '模型停用'
          : !binding.enabled
          ? '未参与此模型'
          : switch (binding.status) {
              ModelQuotaStatus.exhausted => '额度耗尽',
              ModelQuotaStatus.expired => '额度已过期',
              _ =>
                widget.model.preferred?.account.key == account.key
                    ? '新会话首选'
                    : '候选可用',
            };
      action = FSwitch(
        key: ValueKey('model-account-${account.key}'),
        semanticsLabel: '参与此模型路由 ${account.label}',
        value: binding.enabled,
        enabled: !vm.busy,
        onChange: (value) =>
            vm.enableSource(widget.model.id, account.key, value),
      );
    }
    final name = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FButton(
          variant: FButtonVariant.ghost,
          size: FButtonSizeVariant.sm,
          mainAxisSize: MainAxisSize.min,
          onPress: openAccount,
          child: Flexible(child: Text(account.label, softWrap: true)),
        ),
        Text(modelSourceName(account.provider), style: muted),
      ],
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
      key: ValueKey(account.key),
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
                Expanded(
                  flex: 2,
                  child: Align(alignment: Alignment.centerRight, child: action),
                ),
              ],
            )
          else ...[
            Row(
              children: [
                Expanded(child: name),
                const SizedBox(width: 8),
                action,
              ],
            ),
            const SizedBox(height: 6),
            Text('剩余额度 ${_remaining(binding)}'),
            Text(modelExpiryText(binding), style: muted),
            Text(status, style: muted),
          ],
          if (vm.error case final error? when error.accountKey == account.key)
            Semantics(
              liveRegion: true,
              child: Text(
                error.message,
                style: muted.copyWith(color: context.theme.colors.destructive),
              ),
            ),
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
        ],
      ),
    );
  }
}
