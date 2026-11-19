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

import 'account_table_view_model.dart';
import 'desktop_theme.dart';
import 'managed_app.dart';

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
  State<CompactAccountsTable> createState() => CompactAccountsTableState();
}

class CompactAccountsTableState extends State<CompactAccountsTable> {
  final _search = TextEditingController();
  GlobalKey _revealedAccount = GlobalKey();
  String? _highlightedId, _pendingReveal;
  final _horizontalScroll = ScrollController();
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

  double get _rowHeight => ((_preferences?.rowHeight ?? 36) + 26) * _textScale;
  bool get _hasCredits => widget.entries.isEmpty
      ? widget.hasCredits
      : widget.entries.any((e) => e.hasCredits);
  bool get _hasRewards => widget.entries.isEmpty
      ? widget.hasRewards
      : widget.entries.any((e) => e.hasRewards);
  final _model = AccountTableViewModel();

  void showActionRequired() => setState(() {
    _model.clear();
    _search.clear();
    _model.filter = AccountFilter.actionRequired;
  });

  /// A view-only deep link. Exact IDs remain scoped by the owning platform.
  bool revealAccount(String id) {
    if (!widget.entries.any((entry) => entry.id == id)) return false;
    setState(() {
      _search.clear();
      _model.clear();
      _highlightedId = id;
      _revealedAccount = GlobalKey();
      _pendingReveal = id;
    });
    return true;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _preferences = UiPreferencesScope.maybeOf(context);
    final source = AccountPresentationScope.maybeOf(context);
    if (source?.app != _source?.app || source?.registry != _source?.registry) {
      _source = source;
      _publish();
    }
    _model.size = _preferences?.pageSize(_preferenceScope) ?? _model.size;
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
    _horizontalScroll.dispose();
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
    platform: _source == null
        ? null
        : '${_source!.app.label} · ${_source!.app.region}',
    preferenceId: '${_preferenceScope}/$id',
  );

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final rows = _model.rows(widget.entries, _favorite, now);
    if (_pendingReveal != null) {
      final index = rows.indexWhere((entry) => entry.id == _pendingReveal);
      _pendingReveal = null;
      if (index >= 0) {
        _model.page = index ~/ _model.size;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final target = _revealedAccount.currentContext;
          if (mounted && target != null) {
            Scrollable.ensureVisible(target, alignment: 0.25);
          }
        });
      }
    }
    final pages = _model.pages(rows.length);
    final page = _model.currentPage(rows.length);
    final visible = _model.visible(rows);
    final colors = context.theme.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.entries.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16, top: 4),
            child: LayoutBuilder(
              builder: (context, box) {
                final search = FTextField(
                  key: const Key('account-search'),
                  hint: '搜索账号或平台',
                  size: FTextFieldSizeVariant.sm,
                  prefixBuilder: (context, style, variants) =>
                      const Icon(FLucideIcons.search, size: 16),
                  control: FTextFieldControl.managed(
                    controller: _search,
                    onChange: (text) => setState(() {
                      _model.search = text.text;
                      _model.page = 0;
                    }),
                  ),
                );
                final platforms = {
                  for (final e in widget.entries)
                    if (e.appId != null) e.appId!,
                };
                final filters = Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    if (platforms.isNotEmpty)
                      SizedBox(
                        width: 134 * _textScale,
                        child: FSelect<String>(
                          key: const Key('account-platform-filter'),
                          builder: selectFieldSemantics,
                          size: FTextFieldSizeVariant.sm,
                          items: {
                            '全部平台': '',
                            for (final app in ManagedApp.values)
                              if (platforms.contains(app.name) ||
                                  _model.platform == app.name)
                                '${app.label} · ${app.region}': app.name,
                          },
                          control: FSelectControl.lifted(
                            value: _model.platform ?? '',
                            onChange: (value) => setState(() {
                              _model.platform = value == '' ? null : value;
                              _model.page = 0;
                            }),
                          ),
                        ),
                      ),
                    for (final f in AccountFilter.values.where(
                      (f) => _hasCredits || f != AccountFilter.expiring,
                    ))
                      FButton(
                        variant: _model.filter == f
                            ? FButtonVariant.secondary
                            : FButtonVariant.ghost,
                        selected: _model.filter == f,
                        size: FButtonSizeVariant.sm,
                        mainAxisSize: MainAxisSize.min,
                        onPress: () => setState(() {
                          _model.filter = f;
                          _model.page = 0;
                        }),
                        child: Text(f.label),
                      ),
                  ],
                );
                return box.maxWidth >= 760 * _textScale
                    ? Row(
                        children: [
                          SizedBox(width: 200 * _textScale, child: search),
                          const SizedBox(width: 12),
                          Expanded(child: filters),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [search, const SizedBox(height: 8), filters],
                      );
              },
            ),
          ),
        if (visible.isNotEmpty)
          LayoutBuilder(
            builder: (context, box) {
              final columns = _columns;
              if (box.maxWidth < 640) {
                return _narrowRows(visible);
              }
              final minimumWidth =
                  columns.fold(0.0, (sum, column) => sum + column.width) *
                  _textScale;
              final scrolls = box.maxWidth < minimumWidth;
              return RawScrollbar(
                controller: _horizontalScroll,
                thumbVisibility: scrolls,
                scrollbarOrientation: ScrollbarOrientation.top,
                thickness: 5,
                radius: const Radius.circular(3),
                thumbColor: colors.mutedForeground.withValues(alpha: .5),
                child: SingleChildScrollView(
                  key: const Key('account-table-scroll'),
                  controller: _horizontalScroll,
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.only(top: scrolls ? 10 : 0),
                  child: SizedBox(
                    width: math.max(box.maxWidth, minimumWidth),
                    child: Table(
                      columnWidths: {
                        0: const FlexColumnWidth(),
                        for (var i = 1; i < columns.length; i++)
                          i: FixedColumnWidth(columns[i].width * _textScale),
                      },
                      defaultVerticalAlignment:
                          TableCellVerticalAlignment.middle,
                      children: [
                        TableRow(
                          decoration: BoxDecoration(
                            color: context.desktopPalette.sidebar,
                          ),
                          children: [
                            for (final column in columns) _heading(column),
                          ],
                        ),
                        for (final entry in visible)
                          TableRow(
                            key: ValueKey('row-${entry.id}'),
                            decoration: _rowDecoration(entry),
                            children: _fields(entry),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
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
                      _model.clear();
                    }),
                  ),
              ],
            ),
          ),
        if (pages > 1 || _model.size != 10)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Wrap(
              spacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  rows.isEmpty
                      ? '0 个账号'
                      : '${page * _model.size + 1}–${math.min((page + 1) * _model.size, rows.length)} / ${rows.length} 个账号',
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
                      value: _model.size,
                      onChange: (value) {
                        if (value == null) return;
                        setState(() {
                          _model.size = value;
                          _model.page = 0;
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
                          ? () => setState(() => _model.page = page - 1)
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
                          ? () => setState(() => _model.page = page + 1)
                          : null,
                      child: const Icon(FLucideIcons.chevronRight, size: 18),
                    ),
                  ),
                ),
                if (widget.entries.isNotEmpty)
                  FTooltip(
                    tipBuilder: (context, controller) =>
                        Text('余额按官方单位展示 · 点击查看明细和查询时间'),
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

  List<({String label, double width, AccountSort? sort})> get _columns => [
    (
      label: '账号',
      width: widget.entries.any((e) => e.onActivate != null) ? 276 : 220,
      sort: AccountSort.name,
    ),
    if (_hasCredits) ...[
      (label: '即将到期额度', width: 128, sort: null),
      (label: '到期时间', width: 120, sort: AccountSort.expiry),
    ],
    if (_hasRewards) (label: '最近领取时间', width: 132, sort: AccountSort.claim),
    if (_hasCredits) (label: '余额', width: 140, sort: null),
    if (!_hasCredits) (label: '套餐 / 工作区', width: 240, sort: null),
  ];

  Widget _narrowRows(Iterable<AccountTableEntry> visible) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        children: [
          for (final column in _columns)
            if (column.sort != null) _heading(column),
        ],
      ),
      for (final entry in visible)
        Builder(
          builder: (context) {
            final fields = _fields(entry);
            return Container(
              decoration: _rowDecoration(entry),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  fields.first,
                  Wrap(
                    children: [
                      for (int i = 1; i < fields.length; i++)
                        FractionallySizedBox(
                          widthFactor: _textScale > 1.4 ? 1 : .5,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                child: Text(
                                  _columns[i].label,
                                  style: context.theme.typography.body.xs
                                      .copyWith(
                                        color: context
                                            .theme
                                            .colors
                                            .mutedForeground,
                                      ),
                                ),
                              ),
                              fields[i],
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
    ],
  );

  BoxDecoration _rowDecoration(AccountTableEntry entry) => BoxDecoration(
    color: entry.id == _highlightedId ? context.desktopPalette.selected : null,
    border: Border(
      bottom: BorderSide(
        color: context.theme.colors.border.withValues(alpha: .45),
      ),
    ),
  );

  Widget _heading(({String label, double width, AccountSort? sort}) column) {
    final label = column.label, sort = column.sort;
    final active = sort != null && _model.sort == sort;
    final text = Text(
      label,
      textAlign: label == '余额' ? TextAlign.right : TextAlign.start,
      maxLines: 1,
      softWrap: false,
      style: context.theme.typography.body.sm.copyWith(
        fontWeight: FontWeight.w500,
        color: active
            ? context.theme.colors.foreground
            : context.theme.colors.mutedForeground,
      ),
    );
    if (sort == null)
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: text,
      );
    final hint = !active
        ? '按$label升序'
        : _model.descending
        ? '恢复默认排序'
        : '按$label降序';
    return FTooltip(
      tipBuilder: (context, controller) => Text(hint),
      child: FButton(
        key: ValueKey('account-sort-${sort.name}'),
        semanticsTooltip: hint,
        variant: FButtonVariant.ghost,
        size: FButtonSizeVariant.sm,
        mainAxisAlignment: MainAxisAlignment.start,
        style: const FButtonStyleDelta.delta(
          contentStyle: FButtonContentStyleDelta.delta(
            padding: EdgeInsetsGeometryDelta.value(
              EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            ),
          ),
        ),
        onPress: () => setState(() => _model.sortBy(sort)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            text,
            const SizedBox(width: 5),
            Icon(
              active
                  ? (_model.descending
                        ? FLucideIcons.arrowDown
                        : FLucideIcons.arrowUp)
                  : FLucideIcons.chevronsUpDown,
              size: 12,
              color: context.theme.colors.mutedForeground,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _fields(AccountTableEntry entry) => [
    Semantics(
      key: entry.id == _highlightedId ? _revealedAccount : null,
      selected: entry.id == _highlightedId,
      child: _AccountName(
        entry: entry,
        app:
            _source?.app ??
            ManagedApp.values
                .where((app) => app.name == entry.appId)
                .firstOrNull,
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
    ),
    if (_hasCredits) ...[
      entry.hasCredits ? _expiry(entry) : _cell('不适用'),
      entry.hasCredits ? _expiry(entry, time: true) : _cell('不适用'),
    ],
    if (_hasRewards) entry.hasRewards ? _claimTime(entry) : _cell('不适用'),
    if (_hasCredits)
      entry.hasCredits
          ? _actionCell(
              key: 'balance-${entry.id}',
              onPress: () => _details(entry.id),
              child: _cell(
                entry.balance == '—' ? '未知' : entry.balance,
                balance: true,
                tooltip: entry.queriedAt == null
                    ? '查询时间未知 · 查看账号详情'
                    : '${accountDate(entry.queriedAt!)} ${accountTime(entry.queriedAt!)} 查询 · 查看账号详情',
              ),
            )
          : _cell('不适用'),
    if (!_hasCredits) _cell(entry.accountSummary ?? entry.identity),
  ];

  Widget _cell(
    String text, {
    String? tooltip,
    Color? color,
    bool balance = false,
  }) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text(
        text,
        textAlign: balance ? TextAlign.right : TextAlign.start,
        style: context.theme.typography.body.sm.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
          color: color,
          fontWeight: balance ? FontWeight.w600 : FontWeight.w400,
        ),
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
    if (receipt == null) return _cell('暂无回执', tooltip: '暂无已确认的领取记录');
    return _actionCell(
      key: 'claim-${row.id}',
      onPress: () => _details(row.id),
      child: receipt.confirmedAt != null
          ? _dateCell(receipt.confirmedAt!)
          : _cell(
              receipt.day ?? '—',
              tooltip: '已确认领取，具体时间未知',
              color: context.theme.colors.mutedForeground,
            ),
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
    if (expiry == null) return _cell('未知', tooltip: '平台未提供可核实的到期信息');
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
                _cell(
                  row.upcomingExpiryAmount == '—'
                      ? '未知'
                      : row.upcomingExpiryAmount,
                  color: color,
                ),
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
    this.app,
    required this.favorite,
    required this.onFavorite,
    required this.onDetails,
    required this.height,
  });
  final AccountTableEntry entry;
  final ManagedApp? app;
  final bool favorite;
  final double height;
  final VoidCallback onFavorite, onDetails;
  @override
  Widget build(BuildContext context) {
    final e = entry;
    final muted = context.theme.typography.body.xs.copyWith(
      color: context.theme.colors.mutedForeground,
    );
    final description = [
      e.label,
      if (e.sourceLabel != null) e.sourceLabel!,
      if (e.identity != e.label) e.identity,
      e.status,
    ].join('\n');
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
          if (app case final platform?)
            Image.asset(platform.iconAsset, width: 23, height: 23),
          Expanded(
            child: FTooltip(
              tipBuilder: (context, controller) => Text(description),
              child: FButton(
                key: ValueKey('account-${e.id}'),
                semanticsTooltip: description,
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.start,
                onPress: onDetails,
                style: const FButtonStyleDelta.delta(
                  contentStyle: FButtonContentStyleDelta.delta(
                    padding: EdgeInsetsGeometryDelta.value(
                      EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                    ),
                  ),
                ),
                child: Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.theme.typography.body.sm.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        [
                          if (e.sourceLabel != null) e.sourceLabel!,
                          e.statusLabel ?? e.status,
                        ].join(' · '),
                        style: muted,
                        maxLines: 1,
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
              variant: FButtonVariant.ghost,
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
