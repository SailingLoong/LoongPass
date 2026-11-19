import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'desktop_theme.dart';

class WorkspaceToolbar extends StatelessWidget {
  const WorkspaceToolbar({
    super.key,
    required this.section,
    required this.leaf,
    required this.narrow,
    required this.onToggle,
    this.action,
  });
  final String section;
  final String? leaf;
  final bool narrow;
  final VoidCallback onToggle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final style = context.theme.typography.body.xs.copyWith(
      color: colors.mutedForeground,
    );
    return Container(
      constraints: BoxConstraints(minHeight: narrow ? 46 : 52),
      padding: EdgeInsets.symmetric(horizontal: context.desktopGutter),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: DefaultTextStyle(
        style: style,
        child: Row(
          children: [
            FButton.icon(
              key: const Key('toggle-sidebar'),
              variant: FButtonVariant.ghost,
              size: FButtonSizeVariant.sm,
              semanticsLabel: '展开或收起主导航',
              onPress: onToggle,
              child: const Icon(FLucideIcons.panelLeft, size: 17),
            ),
            const SizedBox(width: 8),
            if (!narrow) ...[
              const Text('本机工作区'),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('/'),
              ),
            ],
            Expanded(
              child: Text(
                [section, ?leaf].join('  /  '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style.copyWith(color: colors.foreground),
              ),
            ),
            if (!narrow || action == null) _LocalDate(short: narrow),
            if (action != null)
              Flexible(
                fit: FlexFit.loose,
                child: Align(alignment: Alignment.centerRight, child: action),
              ),
          ],
        ),
      ),
    );
  }
}

class _LocalDate extends StatefulWidget {
  const _LocalDate({required this.short});
  final bool short;
  @override
  State<_LocalDate> createState() => _LocalDateState();
}

class _LocalDateState extends State<_LocalDate> with WidgetsBindingObserver {
  Timer? _midnight;
  late DateTime _today;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  void _refresh() {
    _midnight?.cancel();
    _today = DateTime.now();
    final tomorrow = DateTime(_today.year, _today.month, _today.day + 1);
    _midnight = Timer(tomorrow.difference(_today), () => setState(_refresh));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) setState(_refresh);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _midnight?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final date = '${_today.month} 月 ${_today.day} 日';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          FLucideIcons.calendarDays,
          size: 15,
          color: context.theme.colors.mutedForeground,
        ),
        const SizedBox(width: 6),
        Text(widget.short ? date : '$date，星期${'一二三四五六日'[_today.weekday - 1]}'),
      ],
    );
  }
}
