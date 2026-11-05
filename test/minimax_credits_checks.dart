import '../lib/minimax_credits.dart';

void main() {
  final now = DateTime.utc(2026, 11, 6);
  Map<String, dynamic> row(num amount, int day) => {
    'credit_type': 2,
    'granted_amount': 100,
    'remaining_amount': amount,
    'consumed_amount': 100 - amount,
    'granted_at_ms': now.millisecondsSinceEpoch - 1000,
    'expire_at_ms': now.add(Duration(days: day)).millisecondsSinceEpoch,
  };
  final a = {...row(70, 1), 'remaining_amount': '70'},
      b = row(20, 1),
      later = row(90, 2),
      old = row(100, -1),
      spent = row(0, 1);
  final snapshot = normalizeMiniMaxCredits([
    {
      'details': [a, b],
      'total_count': 5,
    },
    {
      'details': [later, old, spent],
      'total_count': 5,
    },
  ], now: now);
  if (snapshot.totalRemaining != 180 ||
      snapshot.expiring.first.remaining != 90 ||
      snapshot.expiring.length != 2)
    throw StateError('remaining and nearest batch');
  for (final pages in <List<Map<String, dynamic>>>[
    [
      {
        'details': [a],
        'total_count': 2,
      },
    ],
    [
      {
        'details': [a],
        'total_count': 2,
      },
      {
        'details': [b],
        'total_count': 3,
      },
    ],
    [
      {
        'details': [
          {...a, 'remaining_amount': 'not-a-number'},
        ],
        'total_count': 1,
      },
    ],
  ]) {
    try {
      normalizeMiniMaxCredits(pages, now: now);
      throw StateError('invalid accepted');
    } on MiniMaxCreditsError {}
  }
  // Identical rows may be distinct batches: the official API has no row ID.
  final two = normalizeMiniMaxCredits([
    {
      'details': [a, a],
      'total_count': 2,
    },
  ], now: now);
  if (two.totalRemaining != 140) throw StateError('incorrect deduplication');
  print(
    'PASS MiniMax current remaining, earliest expiry, pagination and malformed response',
  );
}
