import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'account_amount.dart';
import 'managed_app.dart';
import 'model_plan_quota.dart';
import 'model_workspace_view_model.dart';
import 'plugin_accounts.dart';
import 'plugin_model_accounts.dart';
import 'plugin_model_catalog.dart';
import 'workspace_page.dart';

class ModelPlansView extends StatelessWidget {
  const ModelPlansView({
    super.key,
    required this.model,
    required this.vm,
    this.onOpenAccount,
  });
  final PluginModel model;
  final ModelWorkspaceViewModel vm;
  final ValueChanged<PluginAccount>? onOpenAccount;

  void _open(BuildContext context, AccountPlan plan) =>
      Navigator.of(context).push<void>(
        PageRouteBuilder<void>(
          settings: const RouteSettings(name: '/models/plan'),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (context, _, _) => ListenableBuilder(
            listenable: Listenable.merge([vm, vm.service]),
            builder: (context, _) {
              final current = vm.service.catalog
                  .where((m) => m.id == model.id)
                  .firstOrNull;
              final members = current == null
                  ? const <PluginModelBinding>[]
                  : modelPlans(current)[plan] ?? const <PluginModelBinding>[];
              final pending = {
                for (final b in members)
                  if (!b.grant.enabled && !b.grant.authorizationRequired)
                    b.account.registration,
              };
              return WorkspacePage(
                title: plan.name ?? '套餐待核实',
                subtitle: modelSourceName(plan.provider),
                action: FButton(
                  variant: FButtonVariant.outline,
                  size: FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => Navigator.of(context).pop(),
                  child: const Text('返回模型'),
                ),
                children: [
                  if (pending.isNotEmpty)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: FButton(
                        size: FButtonSizeVariant.sm,
                        mainAxisSize: MainAxisSize.min,
                        onPress: vm.busy
                            ? null
                            : () => vm.authorizeRegistrations(pending, true),
                        child: Text('为 ${pending.length} 个账号开放模型权限'),
                      ),
                    ),
                  if (vm.error case final error? when error.accountKey == null)
                    Text(error.message),
                  if (current != null && members.isNotEmpty)
                    PluginModelAccounts(
                      model: current,
                      plan: plan,
                      vm: vm,
                      onOpenAccount: onOpenAccount,
                    )
                  else
                    const Text('此套餐当前没有适用来源。'),
                ],
              );
            },
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => WorkspaceCard(
    child: Column(
      children: [
        for (final group in modelPlans(model).entries)
          Builder(
            builder: (context) {
              final plan = group.key, bindings = group.value;
              final app = ManagedApp.forProvider(plan.provider);
              final quota = modelPlanQuota(bindings, DateTime.now());
              final title =
                  '${app?.label ?? plan.provider} · ${plan.name ?? '套餐待核实'}';
              final scope = {
                if (app != null) app.region,
                if (plan.realm.isNotEmpty &&
                    plan.realm != 'cn' &&
                    plan.realm != 'global')
                  plan.realm,
              };
              final facts = <String>[
                if (scope.isNotEmpty) scope.join(' · '),
                if (!model.published) '模型未启用',
                if (bindings.every((b) => b.grant.authorizationRequired))
                  '需要重新登录'
                else if (bindings.every((b) => !b.grant.enabled))
                  '未开放模型权限'
                else if (quota.exhausted)
                  '适用额度已用完或到期'
                else if (bindings.every((b) => !b.enabled))
                  '未参与此模型'
                else if (quota.shared)
                  '额度共享范围待核实'
                else if (quota.amounts.isEmpty)
                  '适用额度待核实'
                else ...[
                  for (final entry in quota.amounts.entries)
                    [
                      if (quota.partial) '已知',
                      if (quota.amounts.length > 1) entry.key.name,
                      groupAccountAmount(
                        '${entry.value} ${entry.key.unit == 'credits' ? '积分' : entry.key.unit}',
                      ),
                      if (entry.key.reset.isNotEmpty)
                        '${DateTime.parse(entry.key.reset).toLocal().toString().substring(0, 16)} 重置',
                    ].join(' '),
                ],
              ];
              return FItem(
                key: ValueKey(plan),
                prefix: app == null
                    ? const Icon(FLucideIcons.layers)
                    : Image.asset(
                        app.iconAsset,
                        width: 30,
                        height: 30,
                        excludeFromSemantics: true,
                      ),
                title: Text(title),
                subtitle: Text(facts.join(' · ')),
                suffix: const Icon(FLucideIcons.chevronRight, size: 16),
                onPress: () => _open(context, plan),
              );
            },
          ),
      ],
    ),
  );
}
