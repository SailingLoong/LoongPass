import 'package:flutter_test/flutter_test.dart';

import '../lib/account_table_entry.dart';
import '../lib/plugin_accounts.dart';
import '../lib/plugin_credit_balance.dart';

void main() {
  group('ZCode Start Plan expiry', () {
    final now = DateTime.now().toUtc();
    final at = DateTime.utc(now.year, now.month, now.day + 2);
    final window = {
      'name': 'GLM-5.1-Trial · Start Plan',
      'models': ['GLM-5.1-Trial'],
      'unit': '',
      'runsOutAt': at.toIso8601String(),
      'runsOut': 100,
    };
    final bucket = {
      'label': 'GLM-5.1',
      'expiresAt': at.millisecondsSinceEpoch ~/ 1000,
      'remaining': 100,
      'unit': 'tokens',
    };
    final usage = {
      'windows': [window],
    };
    PluginAccount accountWith(
      Map<String, dynamic>? native,
      Map reward, {
      DateTime? queriedAt,
    }) => PluginAccount(
      key: 'saved',
      facts: {'provider': 'zcode', 'reward': reward},
      active: true,
      models: [],
      usage: native,
      queriedAt: queriedAt,
    );
    test('a newer observed gift replaces the expired reward snapshot', () {
      final yesterday = now.subtract(const Duration(days: 1));
      final reward = {
        'checkedAt': yesterday
            .subtract(const Duration(hours: 1))
            .millisecondsSinceEpoch,
        'buckets': [
          {...bucket, 'expiresAt': yesterday.millisecondsSinceEpoch ~/ 1000},
        ],
      };
      // A failed later RPC annotates the cached successful map without
      // changing its windows or queriedAt.
      for (final cached in [
        usage,
        {...usage, 'error': 'Usage query unavailable'},
      ]) {
        final account = accountWith(cached, reward, queriedAt: now);
        expect(account.usesZcodeRewardExpiry, isFalse);
        expect(account.creditExpiryBatches.single.at, at);
        expect(account.creditExpiry!.at, at);
        expect(account.creditExpiry!.amount, isNull);
      }
    });
    test('newer native gifts retain independent same-time units without borrowing from a bucket', () {
      final reward = {
        'checkedAt': now.millisecondsSinceEpoch - 1,
        'buckets': [bucket],
      };
      final account = accountWith(
        {
          'windows': [
            window,
            {...window, 'aside': true, 'runsOut': 13.25, 'unit': 'credits'},
          ],
        },
        reward,
        queriedAt: now,
      );
      expect(
        account.creditExpiryBatches.map(
          (b) => (b.at, b.amount?.amount, b.amount?.unit),
        ),
        unorderedEquals([(at, null, null), (at, 13.25, 'credits')]),
      );
      expect(account.creditExpiry!.amount, isNull);
    });
    test('Coding Plan alone cannot displace a verified gift snapshot', () {
      final reward = {
        'checkedAt': now.millisecondsSinceEpoch - 1,
        'buckets': [bucket],
        'status': 'unknown',
      };
      for (final windows in [
        [],
        [
          {'name': 'Coding Plan', 'resetsAt': at.toIso8601String()},
        ],
        [
          {...window, 'runsOutAt': 'invalid'},
        ],
      ]) {
        final account = accountWith(
          {'windows': windows},
          reward,
          queriedAt: now,
        );
        expect(account.usesZcodeRewardExpiry, isTrue);
        final batch = account.creditExpiryBatches.single;
        expect(
          (batch.at, batch.amount?.amount, batch.amount?.unit),
          (at, 100, 'tokens'),
        );
      }
    });
    test('an observed empty bucket list clears earlier native evidence and wins ties', () {
      for (final delta in [0, 1]) {
        final account = accountWith(usage, {
          'checkedAt': now.millisecondsSinceEpoch + delta,
          'buckets': [],
        }, queriedAt: now);
        expect(account.usesZcodeRewardExpiry, isTrue);
        expect(account.creditExpiryBatches, isEmpty);
        expect(account.creditExpiry, isNull);
      }
    });
    test(
      'the journal and native window project one remaining 100-token batch',
      () {
        final reward = {
          'buckets': [bucket],
        };
        final account = accountWith(usage, reward);
        final batches = account.creditExpiryBatches;
        expect(batches, hasLength(1));
        expect(
          (
            batches.single.at,
            batches.single.amount?.amount,
            batches.single.amount?.unit,
          ),
          (at, 100, 'tokens'),
        );
        final next = account.creditExpiry!;
        expect(
          (next.at, next.amount?.amount, next.amount?.unit),
          (at, 100, 'tokens'),
        );
      },
    );
    test('independent entitlements at one instant retain each original amount and unit', () {
      for (final secondUnit in ['tokens', 'credits']) {
        final reward = {
          'buckets': [
            bucket,
            {...bucket, 'unit': secondUnit},
          ],
        };
        for (final source in [usage, null]) {
          final account = accountWith(source, reward);
          final batches = account.creditExpiryBatches;
          expect(
            batches.map((b) => (b.at, b.amount?.amount, b.amount?.unit)),
            unorderedEquals([(at, 100, 'tokens'), (at, 100, secondUnit)]),
          );
          final next = account.creditExpiry!;
          expect(next.at, at);
          expect(next.amount, isNull);
        }
      }
    });
    test('observed empty or unknown owner facts supersede older windows', () {
      for (final reward in [
        {'checkedAt': now.millisecondsSinceEpoch, 'buckets': []},
        {
          'buckets': [
            {...bucket, 'remaining': 0},
          ],
        },
        {
          'buckets': [
            {...bucket, 'expiresAt': null},
          ],
        },
      ]) {
        final account = accountWith(usage, reward);
        expect(account.creditExpiryBatches, isEmpty);
        expect(account.creditExpiry, isNull);
      }
      final unknown = accountWith(usage, {
        'buckets': [
          {...bucket, 'remaining': null},
        ],
      }).creditExpiryBatches.single;
      expect(unknown.at, at);
      expect(unknown.amount, isNull);
    });
    test(
      'before an owner balance read, native gift windows remain independent',
      () {
        final native = {
          'windows': [
            window,
            {...window, 'aside': true},
          ],
        };
        for (final reward in [
          <String, dynamic>{},
          {'buckets': []},
        ]) {
          final batches = accountWith(native, reward).creditExpiryBatches;
          expect(batches.map((b) => (b.at, b.amount)), [
            (at, null),
            (at, null),
          ]);
        }
      },
    );
  });
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
        'windows': [
          daily,
          permanent,
          {'name': '积分合计', 'balance': 47.65625, 'unit': 'credits'},
        ],
      })!.amount,
      47.65625,
    );
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
