import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart' show SelectableText;

import 'account_amount.dart';
import 'account_table_entry.dart';
import 'credit_summary_view.dart';
import 'desktop_theme.dart';
import 'managed_app.dart';
import 'ui_preferences.dart';

part 'account_detail_sections.dart';

enum AccountDetailSection { summary, expiry, receipt, quota, profile }

/// Pushes an opaque page into the workspace navigator. Opening it consumes the
/// owner's latest snapshot; reads never initiate a query or a reward action.
Future<void> showAccountDetails(
  BuildContext context, {
  required Listenable listenable,
  required AccountTableEntry? Function() read,
  AccountExpiryBatch? batch,
  AccountDetailSection section = AccountDetailSection.summary,
  ManagedApp? app,
  String? preferenceId,
}) async {
  final row = read();
  final preferences = UiPreferencesScope.maybeOf(context);
  row?.onOpenDetails?.call();
  await Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      settings: RouteSettings(name: '/accounts/${row?.id}'),
      pageBuilder: (_, animation, secondaryAnimation) => _AccountDetailPage(
        listenable: listenable,
        read: read,
        app: app,
        preferences: preferences,
        preferenceId: preferenceId,
        initial: batch != null ? AccountDetailSection.expiry : section,
        batch: batch,
      ),
    ),
  );
}

class _AccountDetailPage extends StatefulWidget {
  const _AccountDetailPage({
    required this.listenable,
    required this.read,
    required this.initial,
    this.preferences,
    this.preferenceId,
    this.app,
    this.batch,
  });
  final Listenable listenable;
  final AccountTableEntry? Function() read;
  final AccountDetailSection initial;
  final UiPreferences? preferences;
  final String? preferenceId;
  final ManagedApp? app;
  final AccountExpiryBatch? batch;
  @override
  State<_AccountDetailPage> createState() => _AccountDetailPageState();
}

class _AccountDetailPageState extends State<_AccountDetailPage> {
  late var section = widget.initial;
  late final _changes = Listenable.merge([
    widget.listenable,
    widget.preferences,
  ]);
  final _scroll = ScrollController();
  double _summaryOffset = 0;
  void _show(AccountDetailSection next) {
    if (_scroll.hasClients) {
      if (section == AccountDetailSection.summary)
        _summaryOffset = _scroll.offset;
      _scroll.jumpTo(0);
    }
    setState(() => section = next);
    if (next == AccountDetailSection.summary) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(
            _summaryOffset.clamp(0.0, _scroll.position.maxScrollExtent),
          );
        }
      });
    }
  }

  void _back() {
    if (section != widget.initial && widget.read() != null) {
      _show(widget.initial);
    } else {
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Widget _inset(Widget child) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 940),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: context.desktopGutter),
        child: child,
      ),
    ),
  );

  Widget _body(AccountTableEntry? row, String? source) {
    if (row == null) return const Text('该账号已不在保存列表中。');
    final theme = context.theme;
    final summary = section == AccountDetailSection.summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (row.notice case final notice?)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Semantics(liveRegion: true, child: Text(notice)),
          ),
        if (summary && row.needsAttention)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              row.status,
              style: theme.typography.body.sm.copyWith(
                color: context.desktopPalette.warning,
              ),
            ),
          ),
        if (!summary)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Semantics(
              header: true,
              child: Text(
                section.title,
                style: theme.typography.display.sm.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        switch (section) {
          AccountDetailSection.summary => _AccountSummary(
            row: row,
            onOpen: _show,
          ),
          AccountDetailSection.expiry => _ExpiryDetails(
            row: row,
            batch: widget.batch,
          ),
          AccountDetailSection.receipt => _Receipts(row),
          AccountDetailSection.quota => row.details,
          AccountDetailSection.profile => _AccountProfile(
            row: row,
            source: source,
          ),
        },
      ],
    );
  }

  Widget _page(BuildContext context, Widget? _) {
    final row = widget.read();
    final app =
        widget.app ??
        ManagedApp.values.where((a) => a.name == row?.appId).firstOrNull;
    final source = app == null
        ? row?.sourceLabel ?? row?.detailPlatform
        : '${app.label} · ${app.region}';
    final favoriteId = row?.preferenceId ?? widget.preferenceId;
    final prefs = widget.preferences;
    final theme = context.theme;
    final divider = Container(height: 1, color: theme.colors.border);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _inset(
          _DetailHeader(
            label: row?.label ?? '账号已移除',
            app: app,
            source: source,
            onBack: _back,
            favorite:
                favoriteId != null && (prefs?.isFavorite(favoriteId) ?? false),
            toggleFavorite: row != null && prefs != null && favoriteId != null
                ? () => prefs.toggleFavorite(favoriteId)
                : null,
          ),
        ),
        divider,
        Expanded(
          child: SingleChildScrollView(
            controller: _scroll,
            child: _inset(
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: _body(row, source),
              ),
            ),
          ),
        ),
        if (row?.actions case final actions?) ...[
          divider,
          _inset(
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Align(alignment: Alignment.centerLeft, child: actions),
              ),
            ),
          ),
        ],
      ],
    );
    return ColoredBox(
      key: const Key('account-detail-page'),
      color: theme.colors.background,
      child: DefaultTextStyle(style: theme.typography.body.sm, child: content),
    );
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {const SingleActivator(LogicalKeyboardKey.escape): _back},
    child: Focus(
      autofocus: true,
      child: ListenableBuilder(listenable: _changes, builder: _page),
    ),
  );
}

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({
    required this.label,
    required this.app,
    required this.source,
    required this.onBack,
    required this.favorite,
    required this.toggleFavorite,
  });
  final String label;
  final ManagedApp? app;
  final String? source;
  final bool favorite;
  final VoidCallback onBack;
  final VoidCallback? toggleFavorite;
  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 15),
      child: Row(
        children: [
          FButton.icon(
            key: const Key('account-back'),
            variant: FButtonVariant.ghost,
            semanticsLabel: '返回',
            onPress: onBack,
            child: const Icon(FLucideIcons.arrowLeft, size: 18),
          ),
          const SizedBox(width: 10),
          if (app case final platform?) ...[
            Container(
              width: 42,
              height: 42,
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                border: Border.all(color: theme.colors.border),
                borderRadius: theme.style.borderRadius.lg,
              ),
              child: Image.asset(
                platform.iconAsset,
                excludeFromSemantics: true,
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.typography.display.lg.copyWith(
                      fontSize: 21,
                      height: 1.22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (source != null)
                  Text(
                    source!,
                    style: theme.typography.body.xs.copyWith(
                      color: theme.colors.mutedForeground,
                    ),
                  ),
              ],
            ),
          ),
          if (toggleFavorite != null)
            FButton.icon(
              key: const Key('detail-favorite'),
              variant: FButtonVariant.ghost,
              selected: favorite,
              semanticsLabel: favorite ? '取消收藏' : '收藏账号',
              onPress: toggleFavorite,
              child: Icon(
                FLucideIcons.star,
                size: 18,
                color: favorite
                    ? context.desktopPalette.brand
                    : theme.colors.mutedForeground,
              ),
            ),
        ],
      ),
    );
  }
}
