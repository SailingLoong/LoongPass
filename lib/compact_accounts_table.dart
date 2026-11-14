export 'account_panel_header.dart';

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'account_table_entry.dart';
export 'account_table_entry.dart';
import 'account_details.dart';
import 'select_field_semantics.dart';
import 'ui_preferences.dart';
import 'account_workspace_registry.dart';

class CompactAccountsTable extends StatefulWidget {
  const CompactAccountsTable({
    super.key,
    required this.entries,
    this.preferenceScope = 'accounts',
    this.hasCredits = true,
    this.hasRewards = true,
    this.emptyMessage = '选择平台并添加账号，开始管理你的账号与额度。',
  });
  final List<AccountTableEntry> entries;
  final String preferenceScope, emptyMessage;
  final bool hasCredits, hasRewards;
  @override
  State<CompactAccountsTable> createState() => _CompactAccountsTableState();
}

class _CompactAccountsTableState extends State<CompactAccountsTable> {
  final _search = TextEditingController();
  late final _live = ValueNotifier(widget.entries);
  final _favorites = <String>{};
  UiPreferences? _preferences;
  AccountPresentationScope? _source;
  String get _preferenceScope => _source?.app.name ?? widget.preferenceScope;
  String _preferenceKey(AccountTableEntry entry) =>
      entry.preferenceId ?? '${_preferenceScope}/${entry.id}';
  bool _favorite(AccountTableEntry entry) =>
      _preferences?.isFavorite(_preferenceKey(entry)) ??
      _favorites.contains(entry.id);
  double get _textScale {
    final fontSize = context.theme.typography.body.sm.fontSize!;
    return MediaQuery.textScalerOf(context).scale(fontSize) / fontSize;
  }

  double get _rowHeight => ((_preferences?.rowHeight ?? 36) + 32) * _textScale;
  bool get _hasCredits => widget.entries.isEmpty
      ? widget.hasCredits
      : widget.entries.any((e) => e.hasCredits);
  bool get _hasRewards => widget.entries.isEmpty
      ? widget.hasRewards
      : widget.entries.any((e) => e.hasRewards);
  int _page = 0, _size = 10;
  String _filter = '全部', _sort = '默认排序';
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _preferences = UiPreferencesScope.maybeOf(context);
    final source = AccountPresentationScope.maybeOf(context);
    if (source?.app != _source?.app || source?.registry != _source?.registry) {
      _source = source;
      _publish();
    }
    _size = _preferences?.pageSize(_preferenceScope) ?? _size;
  }

  void _publish() {
    final source = _source;
    if (source == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) source.registry.publish(source.app, this, widget.entries);
    });
  }

  @override
  void didUpdateWidget(covariant CompactAccountsTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Existing dialogs follow owner updates without reloading the owner.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _live.value = widget.entries;
    });
    _publish();
  }

  @override
  void dispose() {
    _search.dispose();
    _live.dispose();
    final source = _source;
    if (source != null)
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => source.registry.remove(source.app, this),
      );
    super.dispose();
  }

  void _details(String id, {bool expiry = false}) => showAccountDetails(
    context,
    listenable: _live,
    read: () => _live.value.where((e) => e.id == id).firstOrNull,
    expiry: expiry,
  );

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final now = DateTime.now(), week = now.add(const Duration(days: 7));
    bool matches(AccountTableEntry e, String filter) => switch (filter) {
      '常用' => _favorite(e),
      '7 天内到期' =>
        e.nextExpiry != null &&
            e.nextExpiry!.isAfter(now) &&
            !e.nextExpiry!.isAfter(week),
      '待处理' => e.needsAttention,
      _ => true,
    };
    final rows = widget.entries
        .where(
          (e) =>
              '${e.label} ${e.identity} ${e.sourceLabel ?? ''}'
                  .toLowerCase()
                  .contains(query) &&
              matches(e, _filter),
        )
        .toList();
    if (_sort == '默认排序') {
      final positions = {
        for (var i = 0; i < widget.entries.length; i++) widget.entries[i].id: i,
      };
      rows.sort((a, b) {
        final favorites = (_favorite(b) ? 1 : 0).compareTo(
          _favorite(a) ? 1 : 0,
        );
        return favorites != 0
            ? favorites
            : positions[a.id]!.compareTo(positions[b.id]!);
      });
    }
    if (_sort == '到期优先')
      rows.sort((a, b) {
        final x = a.nextExpiry, y = b.nextExpiry;
        return x == null
            ? (y == null ? 0 : 1)
            : y == null
            ? -1
            : x.compareTo(y);
      });
    if (_sort == '账号名称') rows.sort((a, b) => a.label.compareTo(b.label));
    final pages = math.max(1, (rows.length / _size).ceil());
    final page = math.min(_page, pages - 1);
    final visible = rows.skip(page * _size).take(_size).toList();
    final colors = context.theme.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.entries.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: LayoutBuilder(
              builder: (context, box) {
                final search = FTextField(
                  key: const Key('account-search'),
                  hint: '搜索账号 / 身份',
                  size: FTextFieldSizeVariant.sm,
                  prefixBuilder: (context, style, variants) =>
                      const Icon(FLucideIcons.search, size: 16),
                  control: FTextFieldControl.managed(
                    controller: _search,
                    onChange: (_) => setState(() => _page = 0),
                  ),
                );
                final sort = FSelect<String>(
                  builder: selectFieldSemantics,
                  key: const Key('account-sort'),
                  size: FTextFieldSizeVariant.sm,
                  items: {
                    '默认排序': '默认排序',
                    if (_hasCredits) '到期优先': '到期优先',
                    '账号名称': '账号名称',
                  },
                  control: FSelectControl.lifted(
                    value: _sort,
                    onChange: (value) {
                      if (value != null)
                        setState(() {
                          _sort = value;
                          _page = 0;
                        });
                    },
                  ),
                );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (box.maxWidth >= 380 * _textScale)
                      Row(
                        children: [
                          Expanded(child: search),
                          const SizedBox(width: 12),
                          SizedBox(width: 132 * _textScale, child: sort),
                        ],
                      )
                    else ...[
                      search,
                      const SizedBox(height: 8),
                      sort,
                    ],
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final f in [
                          '全部',
                          '常用',
                          if (_hasCredits) '7 天内到期',
                          '待处理',
                        ])
                          FButton(
                            variant: _filter == f
                                ? FButtonVariant.secondary
                                : FButtonVariant.ghost,
                            selected: _filter == f,
                            size: FButtonSizeVariant.sm,
                            mainAxisSize: MainAxisSize.min,
                            onPress: () => setState(() {
                              _filter = f;
                              _page = 0;
                            }),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(f),
                                const SizedBox(width: 6),
                                Text(
                                  '${widget.entries.where((e) => matches(e, f)).length}',
                                  style: context.theme.typography.body.xs
                                      .copyWith(color: colors.mutedForeground),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        if (visible.isNotEmpty)
          FCard(
            clipBehavior: Clip.antiAlias,
            child: LayoutBuilder(
              builder: (context, box) => box.maxWidth >= 520 * _textScale
                  ? Table(
                      columnWidths: const {
                        0: FlexColumnWidth(3.4),
                        1: FlexColumnWidth(2),
                        2: FlexColumnWidth(1.6),
                        3: FlexColumnWidth(1.9),
                        4: FlexColumnWidth(1.9),
                      },
                      defaultVerticalAlignment:
                          TableCellVerticalAlignment.middle,
                      children: [
                        TableRow(
                          decoration: BoxDecoration(color: colors.muted),
                          children: [
                            for (final label in _columns) _heading(label),
                          ],
                        ),
                        for (final entry in visible)
                          TableRow(
                            key: ValueKey('row-${entry.id}'),
                            decoration: _rowDecoration,
                            children: _fields(entry),
                          ),
                      ],
                    )
                  : Column(
                      children: [
                        for (final entry in visible)
                          DecoratedBox(
                            key: ValueKey('row-${entry.id}'),
                            decoration: _rowDecoration,
                            child: _stackedFields(entry, box.maxWidth),
                          ),
                      ],
                    ),
            ),
          ),
        if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.entries.isEmpty ? widget.emptyMessage : '没有匹配的账号。'),
                if (widget.entries.isNotEmpty)
                  FButton(
                    variant: FButtonVariant.ghost,
                    size: FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    child: const Text('清除搜索和筛选'),
                    onPress: () => setState(() {
                      _search.clear();
                      _filter = '全部';
                      _page = 0;
                    }),
                  ),
              ],
            ),
          ),
        if (pages > 1 || _size != 10)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Wrap(
              spacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  rows.isEmpty
                      ? '0 个账号'
                      : '${page * _size + 1}–${math.min((page + 1) * _size, rows.length)} / ${rows.length} 个账号',
                  style: context.theme.typography.body.sm,
                ),
                SizedBox(
                  width: 128 * _textScale,
                  child: FSelect<int>(
                    builder: selectFieldSemantics,
                    key: const Key('account-page-size'),
                    size: FTextFieldSizeVariant.sm,
                    items: {
                      for (final size in [5, 10, 20]) '$size 条 / 页': size,
                    },
                    control: FSelectControl.lifted(
                      value: _size,
                      onChange: (value) {
                        if (value == null) return;
                        setState(() {
                          _size = value;
                          _page = 0;
                          _preferences?.setPageSize(_preferenceScope, value);
                        });
                      },
                    ),
                  ),
                ),
                FTooltip(
                  tipBuilder: (context, controller) => Text('上一页'),
                  child: Semantics(
                    tooltip: '上一页',
                    child: FButton.icon(
                      variant: FButtonVariant.ghost,
                      size: FButtonSizeVariant.sm,
                      onPress: page > 0
                          ? () => setState(() => _page = page - 1)
                          : null,
                      child: const Icon(FLucideIcons.chevronLeft, size: 18),
                    ),
                  ),
                ),
                Text(
                  '${page + 1} / $pages',
                  style: context.theme.typography.body.sm,
                ),
                FTooltip(
                  tipBuilder: (context, controller) => Text('下一页'),
                  child: Semantics(
                    tooltip: '下一页',
                    child: FButton.icon(
                      variant: FButtonVariant.ghost,
                      size: FButtonSizeVariant.sm,
                      onPress: page + 1 < pages
                          ? () => setState(() => _page = page + 1)
                          : null,
                      child: const Icon(FLucideIcons.chevronRight, size: 18),
                    ),
                  ),
                ),
                if (widget.entries.isNotEmpty)
                  FTooltip(
                    tipBuilder: (context, controller) =>
                        Text('余额按官方单位展示 · — 表示数据未知 · 点击查看明细和查询时间'),
                    child: Semantics(
                      tooltip: '余额按官方单位展示 · — 表示数据未知 · 点击查看明细和查询时间',
                      child: Icon(
                        FLucideIcons.info,
                        size: 14,
                        color: colors.mutedForeground,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  List<String> get _columns => [
    '账号',
    if (_hasCredits) ...['余额', '即将到期积分', '到期时间'],
    if (_hasRewards) '最近领取时间',
    if (!_hasCredits) '套餐 / 工作区',
  ];

  BoxDecoration get _rowDecoration => BoxDecoration(
    border: Border(
      bottom: BorderSide(
        color: context.theme.colors.border.withValues(alpha: .45),
      ),
    ),
  );

  Widget _heading(String label) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
    child: Text(
      label,
      style: context.theme.typography.body.sm.copyWith(
        fontWeight: FontWeight.w500,
        color: context.theme.colors.mutedForeground,
      ),
    ),
  );

  Widget _stackedFields(AccountTableEntry entry, double width) {
    final fields = _fields(entry);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        fields.first,
        Wrap(
          children: [
            for (var i = 1; i < fields.length; i++)
              SizedBox(
                width: _textScale > 1.5 ? width : width / 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [_heading(_columns[i]), fields[i]],
                ),
              ),
          ],
        ),
      ],
    );
  }

  List<Widget> _fields(AccountTableEntry entry) => [
    _AccountName(
      entry: entry,
      height: _rowHeight,
      favorite: _favorite(entry),
      onFavorite: () => setState(() {
        if (_preferences != null) {
          _preferences!.toggleFavorite(_preferenceKey(entry));
        } else {
          _favorites.contains(entry.id)
              ? _favorites.remove(entry.id)
              : _favorites.add(entry.id);
        }
      }),
      onDetails: () => _details(entry.id),
    ),
    if (_hasCredits) ...[
      entry.hasCredits
          ? _actionCell(
              key: 'balance-${entry.id}',
              onPress: () => _details(entry.id),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _cell(entry.balance),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                    child: Text(
                      entry.queriedAt == null
                          ? '尚无查询时间'
                          : '${accountDate(entry.queriedAt!).substring(5)} ${accountTime(entry.queriedAt!)} 查询',
                      style: context.theme.typography.body.xs.copyWith(
                        color: context.theme.colors.mutedForeground,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : _cell('不适用'),
      entry.hasCredits ? _expiry(entry) : _cell('不适用'),
      entry.hasCredits ? _expiry(entry, time: true) : _cell('不适用'),
    ],
    if (_hasRewards) entry.hasRewards ? _claimTime(entry) : _cell('不适用'),
    if (!_hasCredits) _cell(entry.accountSummary ?? entry.identity),
  ];

  Widget _cell(String text, {String? tooltip, Color? color}) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text(
        text,
        style: context.theme.typography.body.sm.copyWith(color: color),
      ),
    );
    return tooltip == null
        ? content
        : FTooltip(
            tipBuilder: (context, controller) => Text(tooltip),
            child: Semantics(tooltip: tooltip, child: content),
          );
  }

  Widget _dateCell(DateTime date, {Color? color}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          accountDate(date),
          style: context.theme.typography.body.sm.copyWith(color: color),
        ),
        Text(
          accountTime(date),
          style: context.theme.typography.body.xs.copyWith(
            color: color ?? context.theme.colors.mutedForeground,
          ),
        ),
      ],
    ),
  );

  Widget _claimTime(AccountTableEntry row) {
    final receipt = row.receipt;
    if (receipt == null) return _cell('—');
    return _actionCell(
      key: 'claim-${row.id}',
      onPress: () => _details(row.id),
      child: receipt.confirmedAt != null
          ? _dateCell(receipt.confirmedAt!)
          : _cell(receipt.day == null ? '时间未知' : '${receipt.day}\n时间未知'),
    );
  }

  Widget _actionCell({
    required String key,
    required VoidCallback onPress,
    required Widget child,
  }) => ConstrainedBox(
    constraints: BoxConstraints(minHeight: _rowHeight),
    child: FButton(
      key: ValueKey(key),
      variant: FButtonVariant.ghost,
      size: FButtonSizeVariant.sm,
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.start,
      style: const FButtonStyleDelta.delta(
        contentStyle: FButtonContentStyleDelta.delta(
          padding: EdgeInsetsGeometryDelta.value(EdgeInsets.zero),
        ),
      ),
      onPress: onPress,
      child: Expanded(child: child),
    ),
  );

  Widget _expiry(AccountTableEntry row, {bool time = false}) {
    final expiry = row.nextExpiry;
    if (expiry == null) return _cell('—');
    final now = DateTime.now();
    final urgent =
        expiry.isAfter(now) &&
        expiry.isBefore(now.add(const Duration(days: 7)));
    final color = urgent ? context.theme.colors.foreground : null;
    return _actionCell(
      key: '${time ? 'expiry-time' : 'expiry'}-${row.id}',
      onPress: () => _details(row.id, expiry: true),
      child: time
          ? _dateCell(expiry, color: color)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _cell(row.upcomingExpiryAmount, color: color),
                if (urgent)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      '7 天内到期',
                      style: context.theme.typography.body.xs.copyWith(
                        color: context.theme.colors.mutedForeground,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _AccountName extends StatelessWidget {
  const _AccountName({
    required this.entry,
    required this.favorite,
    required this.onFavorite,
    required this.onDetails,
    required this.height,
  });
  final AccountTableEntry entry;
  final bool favorite;
  final double height;
  final VoidCallback onFavorite, onDetails;
  @override
  Widget build(BuildContext context) {
    final e = entry;
    final muted = context.theme.typography.body.xs.copyWith(
      color: context.theme.colors.mutedForeground,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: height),
      child: Row(
        children: [
          FTooltip(
            tipBuilder: (context, controller) =>
                Text(favorite ? '取消常用' : '设为常用'),
            child: Semantics(
              tooltip: favorite ? '取消常用' : '设为常用',
              child: FButton.icon(
                variant: favorite
                    ? FButtonVariant.secondary
                    : FButtonVariant.ghost,
                selected: favorite,
                size: FButtonSizeVariant.sm,
                onPress: onFavorite,
                child: const Icon(FLucideIcons.star, size: 14),
              ),
            ),
          ),
          Expanded(
            child: FTooltip(
              tipBuilder: (context, controller) =>
                  Text('${e.identity}\n${e.status}'),
              child: FButton(
                key: ValueKey('account-${e.id}'),
                semanticsTooltip: '${e.identity}\n${e.status}',
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.start,
                onPress: onDetails,
                child: Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.theme.typography.body.sm.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (e.sourceLabel != null)
                        Text(
                          e.sourceLabel!,
                          style: muted,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      Text(
                        e.statusLabel ?? e.status,
                        style: muted.copyWith(
                          color: e.needsAttention
                              ? context.theme.colors.error
                              : null,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (e.onActivate != null)
            FButton(
              key: ValueKey('activate-${e.id}'),
              variant: FButtonVariant.outline,
              size: FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              onPress: e.activationEnabled ? e.onActivate : null,
              child: const Text('切换'),
            ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}
