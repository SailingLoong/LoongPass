import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'codex_accounts.dart';
import 'compact_accounts_table.dart';

/// Presentation only. The application owns the adapter, so leaving this page
/// neither starts nor cancels native authorization and account observations.
class CodexAccountsPanel extends StatefulWidget {
  const CodexAccountsPanel({super.key, required this.owner});
  final CodexAccounts owner;
  @override
  State<CodexAccountsPanel> createState() => _CodexAccountsPanelState();
}

class _CodexAccountsPanelState extends State<CodexAccountsPanel> {
  bool _confirming = false;

  Future<void> _confirm(String id, {bool remove = false}) async {
    final owner = widget.owner;
    if (!mounted || _confirming || !owner.canMutate) return;
    final account = owner.snapshot.accounts
        .where((a) => a.id == id)
        .firstOrNull;
    if (account == null) return;
    _confirming = true;
    try {
      final allowed = await showFDialog<bool>(
        context: context,
        builder: (context, style, animation) => FDialog(
          animation: animation,
          constraints: const BoxConstraints(minWidth: 280, maxWidth: 640),
          builder: (context, style) => Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DefaultTextStyle(
                  style: style.titleTextStyle,
                  child: Text(remove ? '移除保存的 Codex 账号？' : '切换 Codex 官方账号？'),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: DefaultTextStyle(
                    style: style.bodyTextStyle,
                    child: SizedBox(
                      width: 500,
                      child: SingleChildScrollView(
                        child: Text(
                          '${account.email ?? '邮箱未知'}\n工作区：${account.workspaceId ?? '未知'}\n\n' +
                              (remove
                                  ? '只删除 LoongPass 保存的登录副本，不会退出 Codex 中的账号。'
                                  : '如 Codex 正在运行，将先正常退出，再应用所选登录并重新打开。正在进行的任务可能中断。'
                                        '现有本机项目、对话与设置会保留；云端对话与权限仍由账号所属工作区决定。'
                                        '操作后请在 Codex 中核对登录账号。'),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    FButton(
                      variant: FButtonVariant.ghost,
                      size: FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      key: const Key('codex-confirm-cancel'),
                      child: const Text('取消'),
                      onPress: () => Navigator.pop(context, false),
                    ),
                    FButton(
                      variant: remove
                          ? FButtonVariant.destructive
                          : FButtonVariant.primary,
                      size: FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      key: Key(
                        remove
                            ? 'codex-confirm-remove'
                            : 'codex-confirm-switch',
                      ),
                      child: Text(remove ? '移除保存副本' : '确认切换'),
                      onPress: () => Navigator.pop(context, true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      if (!mounted || !identical(owner, widget.owner) || allowed != true)
        return;
      if (remove) {
        await owner.remove(id);
      } else {
        await owner.activate(id);
      }
    } finally {
      _confirming = false;
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.owner,
    builder: (context, _) {
      final owner = widget.owner;
      final state = owner.snapshot;
      final notice = _activationNotice(owner);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AccountPanelToolbar(
            title: 'Codex',
            accountCount: state.accounts.length,
            helpText:
                '保存多个官方 Codex 登录。授权以明文保存在本机私有目录。'
                '添加账号不会切换官方客户端；切换时只替换登录，保留本机项目、对话与设置。'
                '云端对话、订阅和工作区权限仍属于各官方账号。'
                '移除只删除 LoongPass 的保存副本，不会退出官方客户端。'
                'Codex 未提供签到或积分数据。',
            actions: [
              FButton(
                variant: FButtonVariant.primary,
                size: FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                key: const Key('codex-login'),
                child: const Text('添加官方账号'),
                onPress: owner.canMutate ? owner.startLogin : null,
              ),
              FButton(
                variant: FButtonVariant.outline,
                size: FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                key: const Key('codex-import'),
                child: const Text('导入当前登录'),
                onPress: owner.canMutate ? owner.importCurrent : null,
              ),
              FButton(
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                key: const Key('codex-status'),
                child: const Text('刷新记录'),
                onPress: owner.supported && !owner.reading && !owner.busy
                    ? owner.refreshSnapshot
                    : null,
              ),
              if (state.loginPending)
                FButton(
                  variant: FButtonVariant.ghost,
                  size: FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  key: const Key('codex-cancel-login'),
                  child: const Text('取消授权'),
                  onPress: owner.canCancelLogin ? owner.cancelLogin : null,
                ),
            ],
          ),
          Text(
            '请在 Codex 中核对实际登录账号，“本机登录记录”为最近观察到的认证记录。',
            style: context.theme.typography.body.xs.copyWith(
              color: context.theme.colors.mutedForeground,
            ),
          ),
          if (!owner.hasSnapshot)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('正在读取 Codex 账号记录…'),
            ),
          if (owner.hasSnapshot && !owner.available && owner.error == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_issueText(state.issue)),
            ),
          if (owner.busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: FProgress(),
            ),
          if (state.loginPending)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('请在官方授权窗口完成登录；完成后账号会保存到 LoongPass。'),
            ),
          if (owner.error ?? state.message case final message?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(message),
            ),
          if (notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(notice),
            ),
          CompactAccountsTable(
            preferenceScope: 'codex',
            hasCredits: false,
            hasRewards: false,
            emptyMessage: '添加官方账号，或导入当前登录。保存后可查看工作区、套餐并切换账号。',
            entries: [
              for (final account in state.accounts)
                AccountTableEntry(
                  id: account.id,
                  label: account.email ?? '邮箱未知',
                  identity: account.workspaceId ?? '工作区未知',
                  balance: '未提供',
                  hasCredits: false,
                  hasRewards: false,
                  accountSummary:
                      '${account.plan ?? '套餐未知'} · ${account.workspaceId ?? '工作区未知'}',
                  expiringAmount: '—',
                  status: state.currentId == account.id ? '本机登录记录' : '已保存',
                  observedAt: state.observedAt,
                  onActivate: () => _confirm(account.id),
                  activationEnabled: owner.canMutate,
                  details: _CodexAccountDetails(
                    owner: owner,
                    id: account.id,
                    onSwitch: () => _confirm(account.id),
                    onRemove: () => _confirm(account.id, remove: true),
                  ),
                ),
            ],
          ),
        ],
      );
    },
  );
}

String _issueText(CodexAccountsIssue? issue) => switch (issue) {
  CodexAccountsIssue.unsupportedPlatform => 'Codex 官方账号管理目前仅支持 macOS。',
  CodexAccountsIssue.runtimeUnavailable =>
    '未找到可用的官方 Codex，请安装或更新 Codex 后重启 LoongPass。',
  CodexAccountsIssue.unsupportedStore =>
    '目前仅支持 Codex 的文件登录存储；如自行调整了 Codex 的存储设置，请重启 LoongPass。',
  CodexAccountsIssue.restricted => 'Codex 存在登录或工作区限制，暂时无法管理账号。',
  _ => 'Codex 账号功能暂不可用，请刷新记录后重试。',
};

String? _activationNotice(CodexAccounts owner) => owner.error != null
    ? null
    : switch (owner.snapshot.outcome) {
        CodexActivationOutcome.opened => '登录记录已应用，已重新打开 Codex。请在客户端核对实际账号。',
        CodexActivationOutcome.applied => '登录记录已应用。打开 Codex 后请核对实际账号。',
        CodexActivationOutcome.unchanged => '本机登录记录与所选账号一致；请在客户端核对实际账号。',
        null => null,
      };

class _CodexAccountDetails extends StatelessWidget {
  const _CodexAccountDetails({
    required this.owner,
    required this.id,
    required this.onSwitch,
    required this.onRemove,
  });
  final CodexAccounts owner;
  final String id;
  final VoidCallback onSwitch, onRemove;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: owner,
    builder: (context, _) {
      final state = owner.snapshot;
      final account = state.accounts.where((a) => a.id == id).firstOrNull;
      if (account == null) return const Text('该账号已不在保存列表中。');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('邮箱：${account.email ?? '未知'}'),
          Text('工作区：${account.workspaceId ?? '未知'}'),
          Text('套餐：${account.plan ?? '未知'}'),
          const SizedBox(height: 8),
          Text(
            state.currentId == id ? '本机登录记录，请在 Codex 中核对实际账号。' : '已保存的官方登录',
            style: context.theme.typography.body.xs.copyWith(
              color: context.theme.colors.mutedForeground,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FButton(
                variant: FButtonVariant.primary,
                size: FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                key: Key('codex-switch-$id'),
                child: const Text('切换到此账号'),
                onPress: owner.canMutate ? onSwitch : null,
              ),
              FButton(
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                key: Key('codex-remove-$id'),
                child: const Text('移除保存副本'),
                onPress: owner.canMutate ? onRemove : null,
              ),
            ],
          ),
        ],
      );
    },
  );
}
