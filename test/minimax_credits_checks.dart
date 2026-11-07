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
  final empty = normalizeMiniMaxCredits([
    {
      'total_count': 0,
      'base_resp': {'status_code': 0},
    },
  ], now: now);
  if (empty.totalRemaining != 0 || empty.expiring.isNotEmpty)
    throw StateError('Successful empty ledger is not zero');
  final formatted = normalizeMiniMaxCredits([
    {
      'total_count': 1,
      'base_resp': {'status_code': 0},
      'details': [
        {...row(0, 1), 'remaining_amount': '1,200.50'},
      ],
    },
  ], now: now);
  if (formatted.totalRemaining != 1200.5 ||
      formatted.expiring.single.remaining != 1200.5 ||
      formatted.expiring.single.expiresAt != DateTime.utc(2026, 11, 7))
    throw StateError('Formatted amount or expiry changed units');
  for (final invalid in [
    {
      'total_count': 1,
      'base_resp': {'status_code': 0},
    },
    {
      'total_count': 0,
      'base_resp': {'status_code': 401},
    },
    {'total_count': 0},
  ]) {
    try {
      normalizeMiniMaxCredits([invalid], now: now);
      throw StateError('Unverified or nonempty missing ledger accepted');
    } on MiniMaxCreditsError {}
  }
  print(
    'PASS MiniMax successful empty ledger, formatted amounts and business rejection',
  );
}
