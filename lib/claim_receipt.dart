/// A confirmed receipt projected by its account owner. Observation/attempt time
/// is not a receipt timestamp; old date-only journals retain that uncertainty.
class ClaimReceipt {
  const ClaimReceipt({
    this.amount,
    this.unit = '积分',
    this.amountLabel = '',
    this.confirmedAt,
    this.observedAt,
    this.creditExpiresAt,
    this.day,
  });
  final num? amount;
  final String unit, amountLabel;
  final DateTime? confirmedAt, observedAt, creditExpiresAt;
  final String? day;
  String get display {
    final value = amount;
    final quantity = value == null
        ? '已领取 · 金额未知'
        : '$amountLabel+${value == value.roundToDouble() ? value.toStringAsFixed(0) : value} $unit';
    final time = confirmedAt ?? observedAt;
    final timestamp = time == null
        ? '${day == null ? '' : '$day '}时间未知'
        : "${confirmedAt == null ? '核验于 ' : ''}${time.toLocal().toString().substring(0, 16)}";
    final expiry = creditExpiresAt?.toLocal();
    return [
      quantity,
      timestamp,
      if (expiry != null) '本次到账有效至 ${expiry.toString().substring(0, 16)}',
    ].join(' · ');
  }
}
