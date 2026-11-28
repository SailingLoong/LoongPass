import 'plugin_accounts.dart';
import 'plugin_credit_balance.dart';
import 'plugin_model_catalog.dart';
import 'plugin_model_quota.dart';

Map<AccountPlan, List<PluginModelBinding>> modelPlans(PluginModel model) {
  final groups = <AccountPlan, List<PluginModelBinding>>{};
  for (final binding in model.bindings) {
    final windows = <AccountPlan, List<Map<String, dynamic>>>{};
    for (final w in binding.quota.windows) {
      (windows[binding.account.planForWindow(w)] ??= []).add(w);
    }
    if (windows.isEmpty ||
        windows.values.every((list) => list.every((w) => w['aside'] == true))) {
      (groups[binding.account.plan] ??= []).add(binding);
      continue;
    }
    for (final entry in windows.entries) {
      if (entry.value.every((w) => w['aside'] == true) && windows.length > 1)
        continue;
      final quota = windows.length == 1
          ? binding.quota
          : pluginModelQuota(
              {'windows': entry.value},
              binding.nativeId,
              DateTime.now(),
            );
      (groups[entry.key] ??= []).add(
        PluginModelBinding(
          binding.grant,
          binding.native,
          binding.enabled,
          quota,
        ),
      );
    }
  }
  return groups;
}

typedef QuotaWindow = ({String name, String unit, String reset, num? span});
typedef PlanQuota = ({
  Map<QuotaWindow, num> amounts,
  bool partial,
  bool shared,
  bool exhausted,
});

/// Only numeric, applicable, account-owned windows can establish a total across logins.
PlanQuota modelPlanQuota(List<PluginModelBinding> bindings, DateTime now) {
  final byOwner = <String, Map<QuotaWindow, num?>>{};
  final usable = bindings.where((b) => b.available);
  var partial = false, independent = true;
  for (final b in usable) {
    final account = b.account;
    final owner = account.uid.isEmpty ? account.key : account.uid;
    final wallet = byOwner.putIfAbsent(owner, () => {});
    if (account.error != null ||
        b.native['free'] == true && !b.giftOnly ||
        b.account.provider == 'workbuddy' &&
            b.native['rate'] is num &&
            (b.native['rate'] as num) <= 0) {
      partial = true;
      continue;
    }
    final visible = b.quota.windows.where((w) => w['aside'] != true);
    if (visible.isEmpty) partial = true;
    if (account.provider == 'workbuddy' &&
        b.native['rate'] is! num &&
        !visible.any(
          (w) =>
              (w['models'] as List?)?.isNotEmpty == true ||
              (w['notModels'] as List?)?.isNotEmpty == true,
        )) {
      partial = true;
      continue;
    }
    final seen = <QuotaWindow>{};
    for (final w in visible) {
      final amount = pluginWindowBalance(w);
      final reset = DateTime.tryParse(w['resetsAt'] as String? ?? '');
      if (amount == null ||
          amount.amount < 0 ||
          reset != null && !reset.isAfter(now)) {
        partial = true;
        continue;
      }
      if (w['walletScope'] != 'account' || account.uid.isEmpty)
        independent = false;
      final key = (
        name: w['name'] as String? ?? '额度',
        unit: amount.unit,
        reset: reset?.toUtc().toIso8601String() ?? '',
        span: w['span'] as num?,
      );
      if (!seen.add(key) ||
          wallet.containsKey(key) && wallet[key] != amount.amount) {
        wallet[key] = null;
        partial = true;
      } else {
        wallet[key] = amount.amount;
      }
    }
  }
  final shared =
      byOwner.values.where((w) => w.isNotEmpty).length > 1 && !independent;
  final amounts = <QuotaWindow, num>{};
  if (!shared) {
    for (final wallet in byOwner.values) {
      for (final entry in wallet.entries) {
        if (entry.value case final value?)
          amounts.update(
            entry.key,
            (old) => old + value,
            ifAbsent: () => value,
          );
      }
    }
  }
  final participants = bindings.where((b) => b.enabled && b.grant.available);
  final exhausted =
      participants.isNotEmpty &&
      participants.every(
        (b) =>
            b.status == ModelQuotaStatus.exhausted ||
            b.status == ModelQuotaStatus.expired,
      );
  return (
    amounts: amounts,
    partial: partial,
    shared: shared,
    exhausted: exhausted,
  );
}
