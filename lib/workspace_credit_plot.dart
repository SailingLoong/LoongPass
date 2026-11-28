part of 'workspace_usage.dart';

class _TimelinePlot extends StatelessWidget {
  const _TimelinePlot(
    this.buckets,
    this.selected,
    this.onSelect, {
    required this.hourly,
    required this.source,
    required this.debit,
  });
  final List<TimelineBucket> buckets;
  final DateTime selected;
  final ValueChanged<TimelineBucket> onSelect;
  final bool hourly, debit;
  final CreditSource? source;

  @override
  Widget build(BuildContext context) {
    final palette = context.desktopPalette, colors = context.theme.colors;
    final small = context.theme.typography.body.xs.copyWith(
      color: colors.mutedForeground,
    );
    final unit = source == null ? '批' : _unit(source!.unit);
    final topUnit = debit ? unit : '次';
    final maxUsage = buckets.fold<num>(1, (n, b) => math.max(n, b.usage ?? 0));
    final maxExpiry = buckets.fold<num>(
      1,
      (n, b) => math.max(n, math.max(b.loss, b.forecast)),
    );
    final scale = math.max(maxUsage, maxExpiry);
    final now = buckets.first.now;
    int? current;
    for (var i = 0; i < buckets.length; i++) {
      if (!now.isBefore(buckets[i].start) && now.isBefore(buckets[i].end))
        current = i;
    }
    final nowPart = current == null
        ? null
        : current +
              now.difference(buckets[current].start).inMilliseconds /
                  buckets[current].end
                      .difference(buckets[current].start)
                      .inMilliseconds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 5,
          children: [
            _Legend(debit ? '积分消耗' : '本机调用', palette.brand),
            _Legend('已确认未用', colors.destructive),
            _Legend('将到期', palette.warning, hatched: true),
            Text('◇  余量未知', style: small),
          ],
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, box) {
            final tick = hourly
                ? (box.maxWidth < 450 ? 6 : 3)
                : (box.maxWidth < 460
                      ? 3
                      : box.maxWidth < 700
                      ? 2
                      : 1);
            Widget track(String label, num limit) => Row(
              children: [
                Expanded(child: Text(label, style: small)),
                Text('0–${_quantity(limit)}', style: small),
              ],
            );
            return DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: colors.border),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Column(
                  children: [
                    if (nowPart != null)
                      Align(
                        alignment: Alignment(
                          (nowPart / buckets.length * 2 - 1).clamp(-.84, .84),
                          0,
                        ),
                        child: Text(
                          '现在 ${accountTime(now)}',
                          style: small.copyWith(
                            color: palette.selectedForeground,
                          ),
                        ),
                      ),
                    track(
                      debit
                          ? '已用额度 · ${_provider(source!.provider)}（$topUnit）'
                          : '本机调用 · 全部来源（次）',
                      debit ? scale : maxUsage,
                    ),
                    _track(context, true, debit ? scale : maxUsage, nowPart),
                    const SizedBox(height: 9),
                    track(
                      '到期 · ${source == null ? '全部来源' : _provider(source!.provider)}（$unit）',
                      debit ? scale : maxExpiry,
                    ),
                    _track(context, false, debit ? scale : maxExpiry, nowPart),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        for (var i = 0; i < buckets.length; i++)
                          Expanded(
                            child: Center(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  i % tick != 0
                                      ? ''
                                      : hourly
                                      ? '${buckets[i].start.hour}时'
                                      : '${buckets[i].start.month}/${buckets[i].start.day}',
                                  style: small,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _track(BuildContext context, bool top, num max, double? nowPart) {
    final palette = context.desktopPalette, colors = context.theme.colors;
    return SizedBox(
      height: 58,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < buckets.length; i++)
            Expanded(
              child: Builder(
                builder: (context) {
                  final b = buckets[i];
                  final active =
                      !selected.isBefore(b.start) && selected.isBefore(b.end);
                  final label =
                      '${_dateText(b.start)}${hourly ? ' ${accountTime(b.start)}' : ''} · ${_bucketLabel(b, source, debit)}';
                  return FTooltip(
                    tipBuilder: (_, _) => Text(label),
                    child: Semantics(
                      label: label,
                      selected: active,
                      button: true,
                      child: FTappable(
                        onPress: () => onSelect(b),
                        builder: (context, states, _) => CustomPaint(
                          painter: _BarPainter(
                            b,
                            top,
                            max,
                            active ||
                                states.contains(WidgetState.hovered) ||
                                states.contains(WidgetState.focused),
                            nowPart == null ? null : nowPart - i,
                            palette,
                            colors.border,
                            colors.destructive,
                            colors.mutedForeground,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend(this.label, this.color, {this.hatched = false});
  final String label;
  final Color color;
  final bool hatched;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      CustomPaint(size: const Size(14, 8), painter: _Swatch(color, hatched)),
      const SizedBox(width: 5),
      Text(label, style: context.theme.typography.body.xs),
    ],
  );
}

class _Swatch extends CustomPainter {
  const _Swatch(this.color, this.hatch);
  final Color color;
  final bool hatch;
  @override
  void paint(Canvas canvas, Size size) =>
      _paintBar(canvas, Offset.zero & size, color, hatch);
  @override
  bool shouldRepaint(_Swatch old) => color != old.color || hatch != old.hatch;
}

void _paintBar(Canvas canvas, Rect rect, Color color, bool hatch) {
  if (rect.isEmpty) return;
  final paint = Paint()..color = hatch ? color.withValues(alpha: .13) : color;
  canvas.drawRect(rect, paint);
  if (hatch) {
    canvas.save();
    canvas.clipRect(rect);
    paint
      ..color = color
      ..strokeWidth = 1;
    for (var x = rect.left - rect.height; x < rect.right; x += 4) {
      canvas.drawLine(
        Offset(x, rect.bottom),
        Offset(x + rect.height, rect.top),
        paint,
      );
    }
    canvas.restore();
    canvas.drawRect(rect.deflate(.5), paint..style = PaintingStyle.stroke);
  }
}

class _BarPainter extends CustomPainter {
  const _BarPainter(
    this.b,
    this.top,
    this.scale,
    this.active,
    this.now,
    this.palette,
    this.border,
    this.loss,
    this.muted,
  );
  final TimelineBucket b;
  final bool top, active;
  final num scale;
  final double? now;
  final DesktopPalette palette;
  final Color border, loss, muted;
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width,
        h = size.height - 1,
        rect = Offset.zero & size,
        paint = Paint();
    if (active)
      canvas.drawRect(rect, paint..color = palette.selected);
    else if (b.start.isAfter(b.now))
      canvas.drawRect(rect, paint..color = border.withValues(alpha: .20));
    canvas.drawLine(
      Offset(0, h * .5),
      Offset(w, h * .5),
      paint..color = border.withValues(alpha: .5),
    );
    canvas.drawLine(Offset(0, h), Offset(w, h), paint..color = border);
    void bar(
      num n,
      double left,
      double right,
      Color color, {
      bool hatch = false,
    }) {
      if (n <= 0) return;
      _paintBar(
        canvas,
        Rect.fromLTRB(
          w * left,
          h - math.max(2, (h - 5) * n / scale),
          w * right,
          h,
        ),
        color,
        hatch,
      );
    }

    if (top) {
      if (b.usage != null) bar(b.usage!, .24, .76, palette.brand);
      if (b.usage == null && !b.start.isAfter(b.now))
        canvas.drawLine(
          Offset(w * .44, h - 3),
          Offset(w * .56, h - 3),
          paint..color = muted,
        );
    } else {
      final both = b.loss > 0 && b.forecast > 0;
      bar(b.loss, both ? .10 : .24, both ? .46 : .76, loss);
      bar(
        b.forecast,
        both ? .54 : .24,
        both ? .90 : .76,
        palette.warning,
        hatch: true,
      );
      if (b.unknown > 0) {
        final x = w / 2, y = 7.0;
        final diamond = Path()
          ..moveTo(x, y - 3)
          ..lineTo(x + 3, y)
          ..lineTo(x, y + 3)
          ..lineTo(x - 3, y)
          ..close();
        canvas.drawPath(
          diamond,
          Paint()
            ..color = muted
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4,
        );
      }
    }
    if (now != null && now! >= 0 && now! < 1) {
      for (double y = 0; y < h; y += 6) {
        canvas.drawLine(
          Offset(w * now!, y),
          Offset(w * now!, y + 3),
          Paint()..color = palette.selectedForeground,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) => true;
}
