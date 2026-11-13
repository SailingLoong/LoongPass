/// A confirmed receipt projected by its account owner. Observation/attempt time
/// is not a receipt timestamp; old date-only journals retain that uncertainty.
class ClaimReceipt {
  const ClaimReceipt({
    this.amount,
    this.unit = '积分',
    this.amountLabel = '',
    this.confirmedAt,
    this.observedAt,
    this.day,
  });
  final num? amount;
  final String unit, amountLabel;
  final DateTime? confirmedAt, observedAt;
  final String? day;
  String get display {
    final value = amount;
    final quantity = value == null
        ? '已领取 · 金额未知'
        : '$amountLabel+${value == value.roundToDouble() ? value.toStringAsFixed(0) : value} $unit';
    final time = confirmedAt?.toLocal();
    if (time == null && observedAt != null)
      return '$quantity · 核验于 ${observedAt!.toLocal().toString().substring(0, 16)}';
    return '$quantity · ${time == null ? '${day == null ? '' : '$day '}时间未知' : time.toString().substring(0, 16)}';
  }
}
