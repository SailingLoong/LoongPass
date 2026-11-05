/// Current official remaining amounts, grouped by equal expiry instants.
/// Missing dates are unknown, never an assertion of unlimited validity.
class CreditExpiry {
  final DateTime expiresAt;
  final double remaining;
  const CreditExpiry(this.expiresAt, this.remaining);
}

class CreditSummary {
  final double? totalRemaining;
  final double withoutExpiry;
  final DateTime observedAt;
  final List<CreditExpiry> expiring;
  CreditSummary(
    this.totalRemaining,
    this.withoutExpiry,
    this.observedAt,
    List<CreditExpiry> expiring,
  ) : expiring = List.unmodifiable(expiring);
}
