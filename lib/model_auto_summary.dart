import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'desktop_theme.dart';
import 'magpie_model_routing.dart';
import 'model_plan_quota.dart';
import 'plugin_model_accounts.dart';
import 'plugin_model_catalog.dart';
import 'workspace_page.dart';

extension on AutoRoutingPriority {
  String get label => switch (this) {
    AutoRoutingPriority.modelOrder => '模型优先',
    AutoRoutingPriority.creditExpiry => '积分到期优先',
  };
}

class ModelAutoSummary extends StatelessWidget {
  const ModelAutoSummary({
    super.key,
    required this.priority,
    required this.onOpen,
  });
  final AutoRoutingPriority priority;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => FTile(
    key: const Key('open-auto-routing'),
    prefix: Icon(FLucideIcons.workflow, color: context.desktopPalette.brand),
    title: const Text('LoongPass Auto'),
    subtitle: Text(priority.label),
    suffix: const Icon(FLucideIcons.chevronRight),
    onPress: onOpen,
  );
}

class ModelAutoSettings extends StatelessWidget {
  const ModelAutoSettings({
    super.key,
    required this.routing,
    required this.running,
    required this.busy,
    required this.onChange,
  });
  final MagpieModelRouting routing;
  final bool running;
  final bool busy;
  final ValueChanged<AutoRoutingPriority> onChange;

  @override
  Widget build(BuildContext context) {
    final heading = context.theme.typography.body.sm.copyWith(
      fontWeight: FontWeight.w600,
    );
    final muted = context.theme.typography.body.sm.copyWith(
      color: context.theme.colors.mutedForeground,
    );
    final controls = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('路由策略', style: heading),
        const SizedBox(height: 12),
        for (final value in AutoRoutingPriority.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FRadio(
              label: Text(value.label),
              value: routing.priority == value,
              enabled: !busy,
              onChange: (selected) {
                if (selected) onChange(value);
              },
            ),
          ),
        if (routing.priority == AutoRoutingPriority.creditExpiry)
          Text('到期时间相同时，按 Magpie 顺序选择。', style: muted),
      ],
    );
    final route = routing.preferred;
    final preview = Container(
      key: const Key('auto-route-preview'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.desktopPalette.sidebar,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('新会话首位候选', style: muted),
          const SizedBox(height: 6),
          if (!running)
            const Text('本机服务已关闭')
          else if (route == null)
            const Text('暂无可用套餐')
          else ...[
            Text(
              route.binding.imageOnly
                  ? '${route.model.name} · 图像生成'
                  : route.model.name,
              style: context.theme.typography.body.lg.copyWith(
                color: context.desktopPalette.selectedForeground,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${modelSourceName(route.binding.account.provider)} · ${_planNames(route)}',
            ),
            const SizedBox(height: 4),
            Text(
              route.binding.expiry == null &&
                      routing.priority == AutoRoutingPriority.creditExpiry
                  ? '暂无已知到期积分，按模型顺序选择'
                  : modelExpiryText(route.binding),
              style: muted,
            ),
          ],
        ],
      ),
    );
    return WorkspaceCard(
      child: LayoutBuilder(
        builder: (context, box) {
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          if (box.maxWidth < 520 * scale) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [controls, const SizedBox(height: 12), preview],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: controls),
              const SizedBox(width: 20),
              Expanded(child: preview),
            ],
          );
        },
      ),
    );
  }

  String _planNames(AutoRoute route) {
    final plans = modelPlans(route.model).entries.where(
      (group) => group.value.any(
        (b) =>
            b.account.key == route.binding.account.key &&
            b.nativeId == route.binding.nativeId,
      ),
    );
    return plans.map((p) => p.key.name ?? '套餐待核实').toSet().join('、');
  }
}
