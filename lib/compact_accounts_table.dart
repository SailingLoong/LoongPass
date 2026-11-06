export 'account_panel_header.dart';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'account_table_entry.dart';
export 'account_table_entry.dart';
import 'credit_summary_view.dart';
import 'ui_preferences.dart';
import 'account_workspace_registry.dart';

class CompactAccountsTable extends StatefulWidget {
  const CompactAccountsTable({
    super.key,
    required this.entries,
    this.preferenceScope = 'accounts',
  });
  final List<AccountTableEntry> entries;
  final String preferenceScope;
  @override
  State<CompactAccountsTable> createState() => _CompactAccountsTableState();
}

class _CompactAccountsTableState extends State<CompactAccountsTable> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
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
  double get _rowHeight => _preferences?.rowHeight ?? 36;
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
    _scroll.dispose();
    _live.dispose();
    final source = _source;
    if (source != null)
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => source.registry.remove(source.app, this),
      );
    super.dispose();
  }

  void _details(String id, {bool expiry = false}) {
    widget.entries.where((e) => e.id == id).firstOrNull?.onOpenDetails?.call();
    showDialog<void>(
      context: context,
      builder: (context) => ValueListenableBuilder<List<AccountTableEntry>>(
        valueListenable: _live,
        builder: (context, rows, _) {
          final row = rows.where((r) => r.id == id).firstOrNull;
          return AlertDialog(
            title: Text(
              row == null
                  ? '账号已移除'
                  : '${row.label} · ${expiry ? '积分到期' : '账号详情'}',
            ),
            content: SizedBox(
              width: 600,
              child: SingleChildScrollView(
                child: row == null
                    ? const Text('该账号已不在当前列表中。')
                    : expiry && row.credits != null
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('最近 3 批 · 当前剩余额度'),
                          for (final b in upcomingCreditBatches(
                            row.credits,
                          ).take(3))
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                '${accountPoints(b.remaining)} 积分 · ${creditTime(b.expiresAt)} 到期',
                              ),
                            ),
                          if (row.credits!.withoutExpiry > 0)
                            Text(
                              '另有 ${accountPoints(row.credits!.withoutExpiry)} 积分到期时间未知。',
                            ),
                          Text('查询于 ${creditTime(row.credits!.observedAt)}'),
                          TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                              _details(id);
                            },
                            child: const Text('查看全部账号明细'),
                          ),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (row.notice != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(row.notice!),
                            ),
                          const Text(
                            '最近一次成功领取',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(row.latestClaim),
                          ),
                          const Divider(),
                          row.details,
                        ],
                      ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

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
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 210,
                height: 34,
                child: TextField(
                  key: const Key('account-search'),
                  controller: _search,
                  style: const TextStyle(fontSize: 12),
                  decoration: const InputDecoration(
                    hintText: '搜索账号 / 身份',
                    prefixIcon: Icon(Icons.search, size: 17),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                  ),
                  onChanged: (_) => setState(() => _page = 0),
                ),
              ),
              for (final f in ['全部', '常用', '7 天内到期', '待处理'])
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(32, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    foregroundColor: _filter == f
                        ? colors.primary
                        : colors.onSurfaceVariant,
                    backgroundColor: _filter == f
                        ? colors.primaryContainer
                        : null,
                  ),
                  onPressed: () => setState(() {
                    _filter = f;
                    _page = 0;
                  }),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(f),
                      const SizedBox(width: 4),
                      Text(
                        '${widget.entries.where((e) => matches(e, f)).length}',
                        style: TextStyle(
                          fontSize: 10,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              DropdownButton<String>(
                value: _sort,
                isDense: true,
                underline: const SizedBox(),
                items: [
                  for (final s in ['默认排序', '到期优先', '账号名称'])
                    DropdownMenuItem(value: s, child: Text(s)),
                ],
                onChanged: (s) => setState(() {
                  _sort = s!;
                  _page = 0;
                }),
              ),
            ],
          ),
        ),
        if (visible.isNotEmpty)
          Material(
            color: colors.surfaceContainerLowest,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: colors.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: LayoutBuilder(
              builder: (context, box) => Scrollbar(
                controller: _scroll,
                thumbVisibility: box.maxWidth < 780,
                child: SingleChildScrollView(
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: math.max(780, box.maxWidth),
                    child: Table(
                      columnWidths: const {
                        0: FlexColumnWidth(3.4),
                        1: FlexColumnWidth(1.65),
                        2: FlexColumnWidth(2.4),
                        3: FlexColumnWidth(2.55),
                      },
                      defaultVerticalAlignment:
                          TableCellVerticalAlignment.middle,
                      children: [
                        TableRow(
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerLow,
                          ),
                          children: [
                            for (final label in ['账号', '余额', '即将到期', '最近领取'])
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 10,
                                ),
                                child: Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        for (final e in visible)
                          TableRow(
                            key: ValueKey('row-${e.id}'),
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: colors.outlineVariant.withValues(
                                    alpha: .45,
                                  ),
                                ),
                              ),
                            ),
                            children: [
                              _AccountName(
                                entry: e,
                                height: _rowHeight,
                                favorite: _favorite(e),
                                onFavorite: () => setState(() {
                                  if (_preferences != null) {
                                    _preferences!.toggleFavorite(
                                      _preferenceKey(e),
                                    );
                                  } else {
                                    _favorites.contains(e.id)
                                        ? _favorites.remove(e.id)
                                        : _favorites.add(e.id);
                                  }
                                }),
                                onDetails: () => _details(e.id),
                              ),
                              InkWell(
                                onTap: () => _details(e.id),
                                child: SizedBox(
                                  height: _rowHeight,
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: _cell(
                                      e.balance,
                                      tooltip:
                                          '${e.balance}\n${e.queriedAt == null ? '查询时间未知' : '查询于 ${creditTime(e.queriedAt!)}'}',
                                    ),
                                  ),
                                ),
                              ),
                              _expiry(e),
                              _cell(e.latestClaim),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.entries.isEmpty
                      ? '添加账号后，在这里查看余额、到期与领取记录。'
                      : '没有匹配的账号。',
                ),
                if (widget.entries.isNotEmpty)
                  TextButton(
                    onPressed: () => setState(() {
                      _search.clear();
                      _filter = '全部';
                      _page = 0;
                    }),
                    child: const Text('清除搜索和筛选'),
                  ),
              ],
            ),
          ),
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
                style: const TextStyle(fontSize: 12),
              ),
              DropdownButton<int>(
                key: const Key('account-page-size'),
                value: _size,
                isDense: true,
                underline: const SizedBox(),
                items: [
                  for (final n in [5, 10, 20])
                    DropdownMenuItem(value: n, child: Text('$n 条 / 页')),
                ],
                onChanged: (n) => setState(() {
                  _size = n!;
                  _page = 0;
                  _preferences?.setPageSize(_preferenceScope, n);
                }),
              ),
              IconButton(
                tooltip: '上一页',
                onPressed: page > 0
                    ? () => setState(() => _page = page - 1)
                    : null,
                icon: const Icon(Icons.chevron_left, size: 18),
              ),
              Text(
                '${page + 1} / $pages',
                style: const TextStyle(fontSize: 12),
              ),
              IconButton(
                tooltip: '下一页',
                onPressed: page + 1 < pages
                    ? () => setState(() => _page = page + 1)
                    : null,
                icon: const Icon(Icons.chevron_right, size: 18),
              ),
              if (widget.entries.isNotEmpty)
                Tooltip(
                  message: '余额按官方单位分别列示 · 悬停余额可查看查询时间，点击查看明细',
                  child: Icon(
                    Icons.info_outline,
                    size: 14,
                    color: colors.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _cell(String text, {String? tooltip}) => Tooltip(
    message: tooltip ?? text,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
    ),
  );
  Widget _expiry(AccountTableEntry row) {
    final batches = upcomingCreditBatches(row.credits);
    final text = row.upcomingExpiryText;
    if (batches.isEmpty && row.expiryText == null) return _cell(text);
    return InkWell(
      key: ValueKey('expiry-${row.id}'),
      onTap: () => _details(row.id, expiry: true),
      child: SizedBox(
        height: _rowHeight,
        child: DefaultTextStyle.merge(
          style: TextStyle(
            color:
                row.nextExpiry != null &&
                    row.nextExpiry!.isAfter(DateTime.now()) &&
                    row.nextExpiry!.isBefore(
                      DateTime.now().add(const Duration(days: 7)),
                    )
                ? (Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFFFFC46B)
                      : const Color(0xFF8D5300))
                : null,
          ),
          child: Align(alignment: Alignment.centerLeft, child: _cell(text)),
        ),
      ),
    );
  }
}

class _AccountName extends StatefulWidget {
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
  State<_AccountName> createState() => _AccountNameState();
}

class _AccountNameState extends State<_AccountName> {
  bool _hovered = false, _focused = false;
  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final touch = {
      TargetPlatform.android,
      TargetPlatform.iOS,
    }.contains(defaultTargetPlatform);
    final show = _hovered || _focused || touch;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: FocusableActionDetector(
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        child: SizedBox(
          height: widget.height,
          child: Row(
            children: [
              IconButton(
                tooltip: widget.favorite ? '取消常用' : '设为常用',
                onPressed: widget.onFavorite,
                constraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 32,
                ),
                padding: EdgeInsets.zero,
                icon: Icon(
                  widget.favorite ? Icons.star : Icons.star_outline,
                  size: 15,
                ),
              ),
              Expanded(
                child: Tooltip(
                  message: '${e.identity}\n${e.status}',
                  child: TextButton(
                    key: ValueKey('account-${e.id}'),
                    onPressed: widget.onDetails,
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.onSurface,
                      alignment: Alignment.centerLeft,
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 32),
                    ),
                    child: Text(
                      e.sourceLabel == null
                          ? e.label
                          : '${e.label} · ${e.sourceLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
              if (e.needsAttention)
                Tooltip(
                  message: e.status,
                  child: Icon(
                    Icons.info_outline,
                    size: 15,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              if (e.onActivate != null)
                Opacity(
                  opacity: show ? 1 : 0,
                  child: IgnorePointer(
                    ignoring: !show,
                    child: TextButton(
                      key: ValueKey('activate-${e.id}'),
                      onPressed: e.activationEnabled ? e.onActivate : null,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(44, 30),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      child: const Text('切换', style: TextStyle(fontSize: 11)),
                    ),
                  ),
                ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }
}
