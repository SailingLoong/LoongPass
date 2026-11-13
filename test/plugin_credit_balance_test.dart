import 'package:flutter_test/flutter_test.dart';

import '../lib/account_table_entry.dart';
import '../lib/plugin_credit_balance.dart';

void main() {
  Map<String, dynamic> window(num spent, num limit, {bool aside = false}) => {
    'amount': spent,
    'limit': limit,
    'unit': 'credits',
    'aside': aside,
  };

  test(
    'WorkBuddy total is counted once; zero spent is still a known balance',
    () {
      for (final (extra, spent, expected) in [
        (3400, 0.04, '3899.96'),
        (2550, 0, '3050'),
      ]) {
        final balance = pluginCreditBalance('workbuddy', {
          'windows': [
            window(0, 500, aside: true),
            window(spent, extra, aside: true),
            window(spent, 500 + extra),
          ],
        })!;
        expect(accountPoints(balance.amount), expected);
        expect(balance.unit, 'credits');
      }
    },
  );

  test(
    'remaining credits preserve fractional units across provider contracts',
    () {
      for (final (provider, spent, limit, expected) in [
        ('qoder', 13, 2500, '2487'),
        ('trae', 0.2544, 5500, '5499.7456'),
        ('minimax', 0, 4393.36, '4393.36'),
        ('minimax', 0, 12224, '12224'),
        ('workbuddy', 500, 500, '0'),
      ]) {
        final balance = pluginCreditBalance(provider, {
          'windows': [window(spent, limit)],
        })!;
        expect(accountPoints(balance.amount), expected);
        expect(balance.unit, 'credits');
      }
    },
  );

  test('text, percentages, unknown aggregate and independent windows are not totals', () {
    for (final usage in [
      {'balance': '123 credits'},
      {'balance': 123},
      {'balance': double.nan, 'unit': 'credits'},
      {
        'windows': [
          {'used': 20, 'limit': 100, 'unit': 'credits'},
        ],
      },
      {
        'windows': [
          window(0, 500, aside: true),
          {'unit': 'credits', 'amount': null, 'limit': null},
        ],
      },
      {
        'windows': [window(0, 500), window(0, 1000)],
      },
      {
        'windows': [
          {'amount': 1, 'limit': 100, 'unit': 'tokens'},
        ],
      },
    ]) {
      expect(pluginCreditBalance('fixture', usage), isNull);
    }
    final zero = pluginCreditBalance('fixture', {
      'balance': 0,
      'unit': 'credits',
    })!;
    expect(zero.amount, 0);
    expect(zero.unit, 'credits');
  });

  test('Loomy sums only its complete disjoint daily and permanent wallets', () {
    final daily = {
      'name': '每日赠送积分',
      'balance': 5000,
      'unit': 'credits',
      'aside': true,
    };
    final permanent = {
      'name': '永久积分',
      'balance': 5000,
      'unit': 'credits',
      'aside': true,
    };
    expect(
      pluginCreditBalance('loomy', {
        'windows': [daily, permanent],
      })!.amount,
      10000,
    );
    expect(
      pluginCreditBalance('loomy', {
        'windows': [daily],
      }),
      isNull,
    );
    expect(
      pluginCreditBalance('loomy', {
        'windows': [
          daily,
          {...permanent, 'unit': 'tokens'},
        ],
      }),
      isNull,
    );
  });

  test(
    'expiry uses canonical remaining credits and never reset or plan dates',
    () {
      final now = DateTime.utc(2026, 11, 13), at = DateTime.utc(2026, 11, 15);
      Map<String, dynamic> expiry(num amount, {bool aside = false}) => {
        'runsOutAt': at.toIso8601String(),
        'runsOut': amount,
        'unit': 'credits',
        'aside': aside,
      };
      final next = pluginCreditExpiry(
        {
          'windows': [
            expiry(10, aside: true),
            expiry(20, aside: true),
            expiry(30),
          ],
        },
        {},
        now,
      )!;
      expect(next.at, at);
      expect(next.amount!.amount, 30);
      expect(next.amount!.unit, 'credits');
      expect(
        pluginCreditExpiry(
          {
            'until': at.toIso8601String(),
            'windows': [
              {
                'resetsAt': at.toIso8601String(),
                'unit': 'credits',
                'balance': 100,
              },
              expiry(0),
            ],
          },
          {},
          now,
        ),
        isNull,
      );
      final unknown = pluginCreditExpiry(
        {
          'windows': [
            {'runsOutAt': at.toIso8601String(), 'unit': 'credits'},
          ],
        },
        {},
        now,
      )!;
      expect(unknown.at, at);
      expect(unknown.amount, isNull);
    },
  );

  test(
    'independent expiring model entitlements keep date without an invented sum',
    () {
      final now = DateTime.utc(2026, 11, 13), at = DateTime.utc(2026, 11, 15);
      final bucket = {
        'expiresAt': at.millisecondsSinceEpoch ~/ 1000,
        'remaining': 100,
        'unit': 'tokens',
      };
      final next = pluginCreditExpiry(null, {
        'buckets': [bucket, bucket],
      }, now)!;
      expect(next.at, at);
      expect(next.amount, isNull);
    },
  );
  test(
    'Qoder package expiry remains visible beside a non-expiring aggregate',
    () {
      final now = DateTime.utc(2026, 11, 13), at = DateTime.utc(2026, 11, 15);
      for (final unit in ['credits', 'tokens']) {
        final next = pluginCreditExpiry(
          {
            'windows': [
              {
                ...window(13, 2500),
                'name': 'Total credits',
                'resetsAt': at.toIso8601String(),
              },
              {
                'name': 'Dedicated credits',
                'balance': 100,
                'unit': unit,
                'aside': true,
                'runsOutAt': at.toIso8601String(),
                'runsOut': 100,
              },
            ],
          },
          {},
          now,
        )!;
        expect(next.at, at);
        expect(next.amount!.amount, 100);
        expect(next.amount!.unit, unit);
      }
    },
  );
}
