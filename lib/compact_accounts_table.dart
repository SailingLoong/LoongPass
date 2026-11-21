export 'account_panel_header.dart';

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'account_amount.dart';
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
    this.registry,
    this.hasCredits = true,
    this.hasRewards = true,
    this.emptyMessage = '选择平台并添加账号，开始管理你的账号与额度。',
  });
  final List<AccountTableEntry> entries;
  final AccountWorkspaceRegistry? registry;
  final String preferenceScope, emptyMessage;
  final bool hasCredits, hasRewards;
  @override
  State<CompactAccountsTable> createState() => CompactAccountsTableState();
}

class CompactAccountsTableState extends State<CompactAccountsTable> {
  final _search = TextEditingController();
  GlobalKey _revealedAccount = GlobalKey();
  String? _highlightedId, _pendingReveal, _revealTarget;

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
      _revealTarget = id;
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

    _live.dispose();
    final source = _source;
    if (source != null)
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => source.registry.remove(source.app, this),
      );
    super.dispose();
  }

  void _details(String id, {bool expiry = false}) {
    setState(() => _highlightedId = id);
    final registry = widget.registry ?? _source?.registry;
    final app = _source?.app;
    List<AccountTableEntry> entries() => registry == null
        ? _live.value
        : app == null
        ? registry.entries
        : registry.entriesFor(app);
    showAccountDetails(
      context,
      listenable: registry ?? _live,
      read: () => entries().where((e) => e.id == id).firstOrNull,
      section: expiry
          ? AccountDetailSection.expiry
          : AccountDetailSection.summary,
      app: _source?.app,
      preferenceId: '$_preferenceScope/$id',
    );
  }

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
        if (widget.entries.isNotEmpty) _controls(),
        if (visible.isNotEmpty)
          LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= 620 * _textScale;
              final stacked = box.maxWidth < 360 * _textScale;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!stacked)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 12, 12, 8),
                      child: DefaultTextStyle(
                        style: context.theme.typography.body.xs.copyWith(
                          color: colors.mutedForeground,
                        ),
                        child: Row(
                          children: [
                            const Expanded(flex: 3, child: Text('账号')),
                            Expanded(
                              flex: 2,
                              child: Text(
                                _hasCredits ? '可用余额' : '套餐 / 工作区',
                                textAlign: TextAlign.end,
                              ),
                            ),
                            if (wide && _hasCredits)
                              const Expanded(
                                flex: 2,
                                child: Text('最近到期', textAlign: TextAlign.end),
                              ),
                          ],
                        ),
                      ),
                    ),
                  for (final entry in visible)
                    _accountRow(entry, wide: wide, stacked: stacked),
                ],
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
              ],
            ),
          ),
      ],
    );
  }

  Widget _controls() {
    final platforms = {
      for (final e in widget.entries)
        if (e.appId != null) e.appId!,
    };
    final search = FTextField(
      key: const Key('account-search'),
      hint: '搜索账号或平台',
      size: FTextFieldSizeVariant.sm,
      prefixBuilder: (_, style, variants) =>
          const Icon(FLucideIcons.search, size: 16),
      control: FTextFieldControl.managed(
        controller: _search,
        onChange: (text) => setState(() {
          _model.search = text.text;
          _model.page = 0;
        }),
      ),
    );
    final active =
        _model.platform != null || _model.filter != AccountFilter.all;
    final filter = FPopoverMenu(
      menuAnchor: Alignment.topRight,
      childAnchor: Alignment.bottomRight,
      menuBuilder: (context, controller, _) => [
        FItemGroup(
          children: [
            for (final f in AccountFilter.values.where(
              (f) => _hasCredits || f != AccountFilter.expiring,
            ))
              FItem(
                title: Text(f.label),
                suffix: f == _model.filter
                    ? const Icon(FLucideIcons.check, size: 14)
                    : null,
                onPress: () {
                  setState(() {
                    _model.filter = f;
                    _model.page = 0;
                  });
                  controller.hide();
                },
              ),
          ],
        ),
        if (platforms.isNotEmpty)
          FItemGroup(
            children: [
              for (final app in <ManagedApp?>[
                null,
                ...ManagedApp.values.where((a) => platforms.contains(a.name)),
              ])
                FItem(
                  key: ValueKey('filter-platform-${app?.name}'),
                  title: Text(
                    app == null ? '全部平台' : '${app.label} · ${app.region}',
                  ),
                  suffix: _model.platform == app?.name
                      ? const Icon(FLucideIcons.check, size: 14)
                      : null,
                  onPress: () {
                    setState(() {
                      _model.platform = app?.name;
                      _model.page = 0;
                    });
                    controller.hide();
                  },
                ),
            ],
          ),
      ],
      builder: (context, controller, _) => FButton(
        key: const Key('account-filter'),
        variant: active ? FButtonVariant.secondary : FButtonVariant.ghost,
        selected: active,
        size: FButtonSizeVariant.sm,
        mainAxisSize: MainAxisSize.min,
        prefix: const Icon(FLucideIcons.listFilter, size: 16),
        onPress: controller.toggle,
        child: const Text('筛选'),
      ),
    );
    final favorite = FButton.icon(
      key: const Key('account-favorites'),
      variant: _model.favoritesOnly
          ? FButtonVariant.secondary
          : FButtonVariant.ghost,
      selected: _model.favoritesOnly,
      size: FButtonSizeVariant.sm,
      semanticsLabel: '仅看收藏',
      onPress: () => setState(() {
        _model.favoritesOnly = !_model.favoritesOnly;
        _model.page = 0;
      }),
      child: const Icon(FLucideIcons.star, size: 16),
    );
    final sort = FPopoverMenu(
      menuAnchor: Alignment.topRight,
      childAnchor: Alignment.bottomRight,
      menuBuilder: (context, controller, _) => [
        FItemGroup(
          children: [
            for (final order in <(AccountSort?, bool, String)>[
              (null, false, '默认排序'),
              (AccountSort.name, false, '名称升序'),
              (AccountSort.name, true, '名称降序'),
              if (_hasCredits) ...[
                (AccountSort.expiry, false, '最近到期优先'),
                (AccountSort.expiry, true, '最晚到期优先'),
              ],
              if (_hasRewards) ...[
                (AccountSort.claim, true, '最近领取优先'),
                (AccountSort.claim, false, '最早领取优先'),
              ],
            ])
              FItem(
                title: Text(order.$3),
                suffix: _model.sort == order.$1 && _model.descending == order.$2
                    ? const Icon(FLucideIcons.check, size: 14)
                    : null,
                onPress: () {
                  setState(() {
                    _model.sort = order.$1;
                    _model.descending = order.$2;
                    _model.page = 0;
                  });
                  controller.hide();
                },
              ),
          ],
        ),
      ],
      builder: (context, controller, _) => FButton.icon(
        key: const Key('account-sort'),
        variant: FButtonVariant.ghost,
        size: FButtonSizeVariant.sm,
        semanticsLabel: '排序',
        onPress: controller.toggle,
        child: const Icon(FLucideIcons.arrowUpDown, size: 16),
      ),
    );
    return LayoutBuilder(
      builder: (context, box) {
        // Each popover needs its own traversal anchor in the accessibility tree.
        final controls = Semantics(
          container: true,
          explicitChildNodes: true,
          child: Wrap(
            spacing: 4,
            runSpacing: 2,
            children: [filter, favorite, sort],
          ),
        );
        if (box.maxWidth < 385 * _textScale)
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [search, controls],
          );
        return Row(
          children: [
            Expanded(child: search),
            const SizedBox(width: 8),
            controls,
          ],
        );
      },
    );
  }

  Widget _accountRow(
    AccountTableEntry entry, {
    required bool wide,
    required bool stacked,
  }) {
    final app =
        _source?.app ??
        ManagedApp.values.where((app) => app.name == entry.appId).firstOrNull;
    final platform =
        entry.sourceLabel ??
        (app == null ? entry.detailPlatform : '${app.label} · ${app.region}');
    final muted = context.theme.typography.body.xs.copyWith(
      color: context.theme.colors.mutedForeground,
    );
    final selected = entry.id == _highlightedId;
    final favorite = _favorite(entry);
    final name = Row(
      children: [
        if (app != null) ...[
          Image.asset(
            app.iconAsset,
            width: 25,
            height: 25,
            excludeFromSemantics: true,
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.theme.typography.body.sm.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (entry.noAvailableModels)
                Text(
                  '无可用模型',
                  style: muted.copyWith(color: context.desktopPalette.warning),
                ),
              if (platform != null)
                Text(
                  platform,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
            ],
          ),
        ),
      ],
    );
    final amounts = Column(
      crossAxisAlignment: stacked
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.end,
      children: [
        if (_hasCredits)
          AccountAmount(
            entry.hasCredits ? entry.balance : '不适用',
            style: context.theme.typography.body.md.copyWith(
              fontWeight: FontWeight.w600,
            ),
            unitStyle: muted,
          )
        else
          Text(entry.accountSummary ?? entry.identity, style: muted),
        if (entry.listStatus case final state?)
          Text(
            state,
            style: muted.copyWith(
              color: entry.needsAttention
                  ? context.desktopPalette.warning
                  : context.desktopPalette.selectedForeground,
            ),
          ),
      ],
    );
    final queried = entry.queriedAt;
    final balance = !entry.hasCredits
        ? amounts
        : FTooltip(
            key: ValueKey('balance-${entry.id}'),
            tipBuilder: (context, controller) => Text(
              queried == null
                  ? '查询时间未知 · 查看账号详情'
                  : '${accountDate(queried)} ${accountTime(queried)} 查询 · 查看账号详情',
            ),
            child: amounts,
          );
    final expiry = entry.nextExpiry;
    final identity = FButton(
      key: ValueKey('account-${entry.id}'),
      variant: FButtonVariant.ghost,
      mainAxisAlignment: MainAxisAlignment.start,
      selected: selected,
      style: const FButtonStyleDelta.delta(
        contentStyle: FButtonContentStyleDelta.delta(
          padding: EdgeInsetsGeometryDelta.value(
            EdgeInsets.symmetric(horizontal: 5, vertical: 8),
          ),
        ),
      ),
      onPress: () => _details(entry.id),
      child: Expanded(
        child: stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  name,
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: balance,
                  ),
                ],
              )
            : Row(
                children: [
                  Expanded(flex: 3, child: name),
                  const SizedBox(width: 8),
                  Expanded(flex: 2, child: balance),
                ],
              ),
      ),
    );
    return Container(
      key: ValueKey('row-${entry.id}'),
      constraints: BoxConstraints(minHeight: _rowHeight),
      decoration: BoxDecoration(
        color: selected ? context.desktopPalette.selected : null,
        border: Border(
          left: BorderSide(
            width: 2,
            color: selected
                ? context.desktopPalette.brand
                : const Color(0x00000000),
          ),
          bottom: BorderSide(
            color: context.theme.colors.border.withValues(alpha: .65),
          ),
        ),
      ),
      child: Semantics(
        key: entry.id == _revealTarget ? _revealedAccount : null,
        selected: selected,
        child: Row(
          children: [
            FButton.icon(
              size: FButtonSizeVariant.sm,
              variant: FButtonVariant.ghost,
              semanticsLabel: favorite ? '取消收藏' : '收藏账号',
              selected: favorite,
              onPress: () => setState(() {
                if (_preferences != null) {
                  _preferences!.toggleFavorite(_preferenceKey(entry));
                } else if (favorite) {
                  _favorites.remove(entry.id);
                } else {
                  _favorites.add(entry.id);
                }
              }),
              child: Icon(
                FLucideIcons.star,
                size: 14,
                color: favorite
                    ? context.desktopPalette.brand
                    : context.theme.colors.mutedForeground,
              ),
            ),
            Expanded(flex: 5, child: identity),
            if (wide && _hasCredits)
              Expanded(
                flex: 2,
                child: expiry == null
                    ? Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Text(
                          entry.hasCredits ? '未知' : '不适用',
                          style: muted,
                          textAlign: TextAlign.end,
                        ),
                      )
                    : FButton(
                        key: ValueKey('expiry-${entry.id}'),
                        variant: FButtonVariant.ghost,
                        size: FButtonSizeVariant.sm,
                        onPress: () => _details(entry.id, expiry: true),
                        child: Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                groupAccountAmount(entry.upcomingExpiryAmount),
                              ),
                              Text(
                                '${accountDate(expiry)} ${accountTime(expiry)}',
                                style: muted,
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
            if (entry.onActivate != null)
              FButton(
                key: ValueKey('activate-${entry.id}'),
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                onPress: entry.activationEnabled ? entry.onActivate : null,
                child: const Text('切换'),
              ),
          ],
        ),
      ),
    );
  }
}
