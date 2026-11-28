import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'login_batch.dart';
import 'managed_app.dart';
import 'plugin_model_service.dart';
import 'plugin_rewards.dart';
import 'workspace_page.dart';

class LoginBatchBar extends StatelessWidget {
  const LoginBatchBar({
    super.key,
    required this.batch,
    required this.models,
    required this.rewards,
    required this.onNext,
    this.onConnection,
    this.onModels,
    this.onOtherApp,
    this.onActivate,
  });

  final LoginBatch batch;
  final PluginModelService models;
  final PluginRewards rewards;
  final VoidCallback? onNext, onConnection, onModels, onActivate, onOtherApp;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([batch, models, rewards.batch]),
    builder: (context, _) {
      final saved = batch.current(models.accounts.accounts);
      if (saved.isEmpty) return const SizedBox.shrink();
      final selection = saved.map((a) => a.registration).toSet();
      final grants = {
        for (final g in models.grants)
          if (selection.contains(g.account.registration) &&
              !g.enabled &&
              !g.authorizationRequired)
            g.account.registration,
      };
      final claims = rewards
          .candidatesFor(selection)
          .map((a) => a.registration)
          .toSet();
      final checking = rewards.batch.value;
      final rewardsBusy = checking != null && checking.checked < checking.total;
      final useModels = batch.includeModels && grants.isNotEmpty;
      final useRewards = batch.includeRewards && claims.isNotEmpty;
      final selectModels =
          models.catalogReady &&
          grants.isEmpty &&
          onModels != null &&
          models.catalog.any(
            (m) =>
                m.official &&
                m.bindings.any(
                  (b) => selection.contains(b.account.registration),
                ),
          ) &&
          !models.catalog.any(
            (m) =>
                m.published &&
                m.bindings.any(
                  (b) =>
                      selection.contains(b.account.registration) && b.available,
                ),
          );
      final multipleApps = saved.map((a) => a.provider).toSet().length > 1;
      final names = saved
          .map(
            (a) => multipleApps
                ? '${ManagedApp.forProvider(a.provider)?.label ?? a.provider} · ${a.label}'
                : a.label,
          )
          .join('、');
      final muted = context.theme.typography.body.sm.copyWith(
        color: context.theme.colors.mutedForeground,
      );
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: WorkspaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    FLucideIcons.circleCheck,
                    color: context.theme.colors.primary,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      saved.length == 1
                          ? '已登录 ${saved.single.label}'
                          : '本次已登录 ${saved.length} 个账号',
                      style: context.theme.typography.body.lg.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  FButton(
                    variant: FButtonVariant.ghost,
                    size: FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    onPress: batch.busy ? null : batch.clear,
                    child: Text(
                      grants.isEmpty && batch.result != null ? '完成' : '仅保存',
                    ),
                  ),
                ],
              ),
              if (saved.length > 1 && saved.length <= 3)
                Text(names, style: muted)
              else if (saved.length > 3)
                FAccordion(
                  children: [
                    FAccordionItem(
                      title: Text('查看本次登录名单', style: muted),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(names),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 10),
              if (grants.isNotEmpty || claims.isNotEmpty)
                Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  children: [
                    if (grants.isNotEmpty)
                      FCheckbox(
                        value: batch.includeModels,
                        enabled: !batch.busy,
                        onChange: (v) => batch.choose(models: v),
                        label: Text('用于模型（${grants.length}）'),
                      ),
                    if (claims.isNotEmpty)
                      FCheckbox(
                        value: batch.includeRewards,
                        enabled: !batch.busy && !rewardsBusy,
                        onChange: (v) => batch.choose(rewards: v),
                        label: Text('辅助签到（${claims.length}）'),
                      ),
                  ],
                ),
              if (batch.result != null)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(batch.result!),
                  ),
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FButton(
                    variant: FButtonVariant.outline,
                    size: FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    prefix: const Icon(FLucideIcons.userPlus, size: 16),
                    onPress: batch.busy ? null : onNext,
                    child: const Text('再登录一个'),
                  ),
                  if (onOtherApp != null)
                    FButton(
                      variant: FButtonVariant.ghost,
                      size: FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: batch.busy ? null : onOtherApp,
                      child: const Text('换个应用登录'),
                    ),
                  if (useModels || useRewards)
                    FButton(
                      size: FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: batch.busy || useRewards && rewardsBusy
                          ? null
                          : () => batch.apply(
                              models,
                              rewards,
                              grants: useModels ? grants : {},
                              claims: useRewards ? claims : {},
                            ),
                      child: Text(
                        batch.busy
                            ? '处理中…'
                            : useModels && useRewards
                            ? '开放模型并辅助签到'
                            : useModels
                            ? '开放模型权限'
                            : '开始辅助签到',
                      ),
                    ),
                  if (grants.isEmpty && (selectModels || onConnection != null))
                    FButton(
                      variant: FButtonVariant.outline,
                      size: FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: selectModels ? onModels : onConnection,
                      child: Text(selectModels ? '选择模型' : '连接客户端'),
                    ),
                  if (onActivate != null && saved.length == 1)
                    FButton(
                      variant: FButtonVariant.outline,
                      size: FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: batch.busy ? null : onActivate,
                      child: const Text('使用这个账号'),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
