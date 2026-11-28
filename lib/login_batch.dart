import 'package:flutter/foundation.dart';

import 'plugin_accounts.dart';
import 'plugin_model_service.dart';
import 'plugin_rewards.dart';

/// A selection from this login session. Credentials and permissions stay with
/// their owners. A removed or replaced registration drops out of the selection.
class LoginBatch extends ChangeNotifier {
  final _saved = <String, AccountRegistration>{};

  bool busy = false;
  bool includeModels = true, includeRewards = false;
  String? result;
  bool _closed = false;

  void choose({bool? models, bool? rewards}) {
    if (busy) return;
    includeModels = models ?? includeModels;
    includeRewards = rewards ?? includeRewards;
    notifyListeners();
  }

  void remember(PluginAccount account) {
    result = _saved.containsKey(account.key) ? '这个账号已在本次列表中' : null;
    _saved[account.key] = account.registration;
    notifyListeners();
  }

  List<PluginAccount> current(Iterable<PluginAccount> accounts) => [
    for (final account in accounts)
      if (_saved[account.key] == account.registration && account.active)
        account,
  ];

  Future<void> apply(
    PluginModelService models,
    PluginRewards rewards, {
    required Set<AccountRegistration> grants,
    required Set<AccountRegistration> claims,
  }) async {
    if (busy || grants.isEmpty && claims.isEmpty) return;
    busy = true;
    result = null;
    notifyListeners();
    final messages = <String>[];
    try {
      if (grants.isNotEmpty) {
        await models.enableRegistrations(grants, true);
        messages.add('已为 ${grants.length} 个账号开放模型权限');
      }
      if (claims.isNotEmpty) {
        final check = await rewards.claimSelection(claims);
        if (check != null) {
          messages.add('辅助签到已检查 ${check.checked} 个账号');
          if (check.failures.isNotEmpty)
            messages.add('待核对：${check.failures.join('、')}');
          if (check.balanceUnavailable) messages.add('额度待更新');
        } else {
          messages.add('当前没有待核对的账号');
        }
      }
    } catch (_) {
      messages.add('操作未完成，请核对账号后重试');
    } finally {
      result = messages.join(' · ');
      busy = false;
      includeRewards = false;
      if (!_closed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }

  void clear() {
    if (busy) return;
    result = null;
    includeModels = true;
    includeRewards = false;
    _saved.clear();
    notifyListeners();
  }
}
