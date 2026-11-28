import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'plugin_accounts.dart';
import 'plugin_model_service.dart';
import 'plugin_rewards.dart';

class AccountPlanControls extends StatefulWidget {
  const AccountPlanControls({
    super.key,
    required this.rows,
    required this.plans,
    required this.selected,
    required this.onSelected,
    required this.models,
    required this.rewards,
  });
  final List<PluginAccount> rows;
  final Set<AccountPlan> plans;
  final AccountPlan? selected;
  final ValueChanged<AccountPlan?> onSelected;
  final PluginModelService models;
  final PluginRewards rewards;
  @override
  State<AccountPlanControls> createState() => _AccountPlanControlsState();
}

class _AccountPlanControlsState extends State<AccountPlanControls> {
  bool busy = false;
  String? message;
  Future<void> _apply(Future<void> Function() action, String success) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
      if (mounted) setState(() => message = success);
    } catch (_) {
      if (mounted) setState(() => message = '操作未完成，请核对账号后重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.models, widget.rewards.batch]),
    builder: (context, _) {
      final selected = widget.selected;
      final rows = widget.rows.where(
        (a) => selected == null || a.plans.contains(selected),
      );
      final selection = {for (final a in rows) a.registration};
      final grants = {
        for (final g in widget.models.grants)
          if (selection.contains(g.account.registration) &&
              !g.enabled &&
              !g.authorizationRequired)
            g.account.registration,
      };
      final claims = widget.rewards.candidatesFor(selection);
      final checking = widget.rewards.batch.value;
      final canClaim =
          claims.isNotEmpty &&
          (checking == null || checking.checked >= checking.total);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (widget.plans.length > 1)
                  FButton(
                    variant: selected == null
                        ? FButtonVariant.secondary
                        : FButtonVariant.ghost,
                    size: FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    onPress: () => widget.onSelected(null),
                    child: const Text('全部套餐'),
                  ),
                for (final plan in widget.plans)
                  FButton(
                    variant: plan == selected
                        ? FButtonVariant.secondary
                        : FButtonVariant.ghost,
                    size: FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    onPress: () => widget.onSelected(plan),
                    child: Text(
                      [
                        plan.name ?? '套餐待核实',
                        if (widget.plans.any(
                          (p) => p != plan && p.name == plan.name,
                        ))
                          plan.realm,
                      ].join(' · '),
                    ),
                  ),
              ],
            ),
            if (grants.isNotEmpty || claims.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (grants.isNotEmpty)
                    FButton(
                      variant: FButtonVariant.outline,
                      size: FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: busy
                          ? null
                          : () => _apply(
                              () => widget.models.enableRegistrations(
                                grants,
                                true,
                              ),
                              '已开放 ${grants.length} 个账号的模型权限。',
                            ),
                      child: Text('用于模型（${grants.length}）'),
                    ),
                  if (claims.isNotEmpty)
                    FButton(
                      variant: FButtonVariant.outline,
                      size: FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: busy || !canClaim
                          ? null
                          : () => _apply(
                              () => widget.rewards.claimSelection(selection),
                              '辅助签到已结束，可在「辅助签到」查看各账号结果。',
                            ),
                      child: Text('辅助签到（${claims.length}）'),
                    ),
                ],
              ),
            if (message case final status?)
              Semantics(liveRegion: true, child: Text(status)),
          ],
        ),
      );
    },
  );
}
