part of 'workspace_accounts.dart';

class WorkspaceActivityPage extends StatefulWidget {
  const WorkspaceActivityPage({
    super.key,
    required this.registry,
    this.rewards,
    this.serviceStatus,
  });
  final AccountWorkspaceRegistry registry;
  final PluginRewards? rewards;
  final Widget? serviceStatus;
  @override
  State<WorkspaceActivityPage> createState() => WorkspaceActivityPageState();
}

enum _RewardView {
  accounts('签到账号', '支持辅助签到的账号', '暂无支持辅助签到的已保存账号。'),
  receipts('最近成功领取', '每个账号最近一次成功回执', '暂无已确认的领取记录。'),
  attention('待处理', '需要留意的账号', '暂无待处理的领取记录。');

  const _RewardView(this.label, this.title, this.empty);
  final String label, title, empty;
}

class WorkspaceActivityPageState extends State<WorkspaceActivityPage> {
  var _view = _RewardView.accounts;
  void showReceipts() => setState(() => _view = _RewardView.receipts);
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.registry,
    builder: (context, _) {
      final accounts = widget.registry.accounts;
      return WorkspacePage(
        title: '辅助签到',
        subtitle: '只在你点击后逐个核对账号。未确认的领取不会重复提交。',
        action: widget.rewards == null
            ? null
            : RewardBatchAction(rewards: widget.rewards!),
        children: [
          if (widget.serviceStatus != null) widget.serviceStatus!,
          if (widget.rewards != null)
            RewardBatchStatus(rewards: widget.rewards!),
          if (widget.serviceStatus == null || accounts.isNotEmpty)
            FTabs(
              scrollable: true,
              style: context.desktopTabStyle,
              control: FTabControl.lifted(
                index: _view.index,
                onChange: (index) =>
                    setState(() => _view = _RewardView.values[index]),
              ),
              children: [
                for (final view in _RewardView.values)
                  FTabEntry(
                    label: Text(view.label),
                    child: _RewardRecords(
                      accounts: accounts,
                      registry: widget.registry,
                      view: view,
                    ),
                  ),
              ],
            ),
        ],
      );
    },
  );
}

class _RewardRecords extends StatelessWidget {
  const _RewardRecords({
    required this.accounts,
    required this.registry,
    required this.view,
  });
  final List<WorkspaceAccount> accounts;
  final AccountWorkspaceRegistry registry;
  final _RewardView view;
  @override
  Widget build(BuildContext context) {
    final records = accounts.where((account) {
      final entry = account.entry;
      return entry.hasRewards &&
          switch (view) {
            _RewardView.accounts => true,
            _RewardView.receipts => entry.receipt != null,
            _RewardView.attention => entry.attention != AccountAttention.none,
          };
    }).toList();
    if (view == _RewardView.receipts) {
      records.sort((a, b) {
        final x = a.entry.receipt!.confirmedAt,
            y = b.entry.receipt!.confirmedAt;
        if (x == null) return y == null ? 0 : 1;
        if (y == null) return -1;
        return y.compareTo(x);
      });
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(view.title, records.length),
        if (records.isEmpty)
          _AccountEmpty(
            title: view.empty,
            icon: Icon(switch (view) {
              _RewardView.accounts => FLucideIcons.calendarCheck,
              _RewardView.receipts => FLucideIcons.history,
              _RewardView.attention => FLucideIcons.circleCheck,
            }, size: 28),
          ),
        for (final account in records)
          _AccountLine(
            account,
            registry,
            status: view == _RewardView.receipts
                ? account.entry.receipt!.display
                : null,
            showResolution: view != _RewardView.receipts,
          ),
      ],
    );
  }
}
