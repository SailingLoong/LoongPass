import 'package:flutter/widgets.dart';

/// Presentation only. Keep provider units, decimal precision and unknown values.
final _quantity = RegExp(r'^([+-]?)(\d+)(\.\d+)? (.+)$');
final _thousands = RegExp(r'\B(?=(\d{3})+(?!\d))');

String groupAccountAmount(String value) {
  final match = _quantity.firstMatch(value);
  if (match == null) return value == '—' ? '未知' : value;
  return '${match[1]}${match[2]!.replaceAll(_thousands, ',')}${match[3] ?? ''} ${match[4]}';
}

class AccountAmount extends StatelessWidget {
  const AccountAmount(
    this.value, {
    super.key,
    required this.style,
    required this.unitStyle,
  });
  final String value;
  final TextStyle style, unitStyle;
  @override
  Widget build(BuildContext context) {
    final display = groupAccountAmount(value);
    final match = _quantity.firstMatch(value);
    final unit = match?[4];
    final number = unit == null
        ? display
        : display.substring(0, display.length - unit.length - 1);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: number),
          if (unit != null)
            TextSpan(
              text: ' $unit',
              style: unitStyle.copyWith(letterSpacing: 0),
            ),
        ],
      ),
      style: style.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
    );
  }
}
