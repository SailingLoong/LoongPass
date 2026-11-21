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
  accounts('签到账号', '暂无支持辅助签到的已保存账号。'),
  receipts('最近领取', '暂无已确认的领取记录。'),
  attention('待处理', '暂无待处理的领取记录。');

  const _RewardView(this.label, this.empty);
  final String label, empty;
}

class WorkspaceActivityPageState extends State<WorkspaceActivityPage> {
  var _view = _RewardView.accounts;
  void showReceipts() => setState(() => _view = _RewardView.receipts);
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.registry,
    builder: (context, _) {
      final accounts = widget.registry.accounts;
      final records = {
        for (final view in _RewardView.values)
          view: [
            for (final account in accounts)
              if (account.entry.hasRewards &&
                  switch (view) {
                    _RewardView.accounts => true,
                    _RewardView.receipts => account.entry.receipt != null,
                    _RewardView.attention => account.entry.needsAttention,
                  })
                account,
          ],
      };
      return WorkspacePage(
        title: '辅助签到',
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
                    label: Text('${view.label} ${records[view]!.length}'),
                    child: _RewardRecords(
                      records: records[view]!,
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
    required this.records,
    required this.registry,
    required this.view,
  });
  final List<WorkspaceAccount> records;
  final AccountWorkspaceRegistry registry;
  final _RewardView view;
  @override
  Widget build(BuildContext context) {
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
            receipt: view == _RewardView.receipts,
          ),
      ],
    );
  }
}
