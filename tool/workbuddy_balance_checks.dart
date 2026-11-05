import '../lib/workbuddy_balance.dart';

final now = DateTime.utc(2027, 1, 15);
Map<String, Object?> response(
  String field,
  List<Object?> rows, {
  Object? count,
  bool includeCount = true,
}) => {
  'code': 0,
  'data': {field: rows, if (includeCount) 'TotalCount': count ?? rows.length},
};
Map<String, Object?> resource(
  String id,
  Object? remaining, {
  String code = 'pack',
  Object? expiry,
}) => {
  'ResourceId': id,
  'PackageCode': code,
  'CapacityRemainPrecise': remaining,
  if (expiry != null) 'DeductionEndTime': expiry,
};
double? total({
  List<Object?> summary = const [],
  List<Object?> paid = const [],
  List<Object?> free = const [],
  DateTime? at,
}) => normalizeWorkBuddyBalance(
  response('Packages', summary),
  response('Accounts', paid),
  response('Accounts', free),
  now: at ?? now,
);
void equal(Object? actual, Object? expected) {
  if (actual != expected) throw StateError('Expected $expected; got $actual');
}

void main() {
  var passed = 0, failed = 0;
  void test(String name, void Function() body) {
    try {
      body();
      passed++;
      print('PASS $name');
    } catch (error) {
      failed++;
      print('FAIL $name: $error');
    }
  }

  test(
    'expiry batches use remaining, merge same instant, exclude spent and expired',
    () {
      final credits = normalizeWorkBuddyCredits(
        response('Packages', []),
        response('Accounts', [
          resource('a', 4, expiry: '2027-01-16T08:00:00+08:00'),
          resource('b', 6, expiry: '2027-01-16T00:00:00Z'),
          resource('c', 9, expiry: '2027-01-17T00:00:00Z'),
          resource('spent', 0, expiry: '2027-01-15T01:00:00Z'),
          resource('old', 80, expiry: '2027-01-14T00:00:00Z'),
        ]),
        response('Accounts', [
          resource('a', 4, expiry: '2027-01-16T08:00:00+08:00'),
        ]),
        now: now,
      )!;
      equal(credits.totalRemaining, 19.0);
      equal(credits.expiring.length, 2);
      equal(credits.expiring.first.remaining, 10.0);
      equal(credits.expiring.first.expiresAt, DateTime.utc(2027, 1, 16));
      equal(credits.withoutExpiry, 0.0);
    },
  );
  test('undated balance is not called never-expiring', () {
    final credits = normalizeWorkBuddyCredits(
      response('Packages', []),
      response('Accounts', [resource('a', 7)]),
      response('Accounts', []),
      now: now,
    )!;
    equal(credits.withoutExpiry, 7.0);
    equal(credits.expiring.length, 0);
  });
  test(
    'incomplete page cannot publish partial expiry details',
    () => equal(
      normalizeWorkBuddyCredits(
        response('Packages', []),
        response('Accounts', [
          resource('a', 7, expiry: '2027-01-16'),
        ], count: 2),
        response('Accounts', []),
        now: now,
      ),
      null,
    ),
  );
  test('complete empty branches are genuine zero', () => equal(total(), 0.0));
  test(
    'missing remaining never becomes zero',
    () => equal(
      total(
        summary: [
          {'PackageCode': 'pack'},
        ],
      ),
      null,
    ),
  );
  test(
    'genuine zero is retained',
    () => equal(total(paid: [resource('r', 0)]), 0.0),
  );
  test(
    'numeric strings are trimmed',
    () => equal(total(paid: [resource('r', ' 25.5 ')]), 25.5),
  );
  test(
    'instances sharing package code stay distinct and replace summary',
    () => equal(
      total(
        summary: [
          {'PackageCode': 'pack', 'CycleCapacityRemainPrecise': 65.5},
        ],
        paid: [
          resource('r1', 25.5),
          resource('r2', 40),
          resource('old', 900, expiry: '2027-01-14T00:00:00Z'),
        ],
      ),
      65.5,
    ),
  );
  test(
    'unknown summary aggregate may be resolved by complete detail',
    () => equal(
      total(
        summary: [
          {'PackageCode': 'pack'},
        ],
        paid: [resource('r', 5)],
      ),
      5.0,
    ),
  );
  test(
    'details supersede even a differing sequential summary',
    () => equal(
      total(
        summary: [
          {'PackageCode': 'pack', 'CapacityRemain': 9},
        ],
        paid: [resource('r', 5)],
      ),
      5.0,
    ),
  );
  test(
    'summary package missing from details is retained',
    () => equal(
      total(
        summary: [
          {'PackageCode': 'other', 'CapacityRemain': 7},
        ],
        paid: [resource('r', 5)],
      ),
      12.0,
    ),
  );
  test(
    'identical paid and free resource counted once',
    () => equal(total(paid: [resource('r', 5)], free: [resource('r', 5)]), 5.0),
  );
  test(
    'duplicate object key ordering is irrelevant',
    () => equal(
      total(
        paid: [resource('r', 5)],
        free: [
          {
            'CapacityRemainPrecise': 5,
            'PackageCode': 'pack',
            'ResourceId': 'r',
          },
        ],
      ),
      5.0,
    ),
  );
  test(
    'conflicting duplicate resource is unknown',
    () =>
        equal(total(paid: [resource('r', 5)], free: [resource('r', 9)]), null),
  );
  test(
    'summary duplicate aggregate is not double-counted',
    () => equal(
      total(
        summary: [
          {'PackageCode': 'pack', 'CapacityRemain': 5},
          {'PackageCode': 'pack', 'CapacityRemain': 5},
        ],
      ),
      null,
    ),
  );
  test(
    'detail without resource identity preserves pinned behavior',
    () => equal(
      total(
        paid: [
          {'PackageCode': 'pack', 'CapacityRemain': 5},
        ],
      ),
      5.0,
    ),
  );
  test(
    'summary without package code preserves pinned behavior',
    () => equal(
      total(
        summary: [
          {'CapacityRemain': 5},
        ],
      ),
      5.0,
    ),
  );
  test(
    'size minus used only when remaining fields absent',
    () => equal(
      total(
        paid: [
          {
            'ResourceId': 'r',
            'PackageCode': 'pack',
            'CapacitySizePrecise': 50,
            'CapacityUsedPrecise': 10,
          },
        ],
      ),
      40.0,
    ),
  );
  test(
    'malformed explicit remaining does not use size fallback',
    () => equal(
      total(
        paid: [
          {
            'ResourceId': 'r',
            'PackageCode': 'pack',
            'CapacityRemain': null,
            'CapacitySize': 50,
            'CapacityUsed': 10,
          },
        ],
      ),
      null,
    ),
  );
  test(
    'used above size is not a negative balance',
    () => equal(
      total(
        paid: [
          {
            'ResourceId': 'r',
            'PackageCode': 'pack',
            'CapacitySize': 1,
            'CapacityUsed': 2,
          },
        ],
      ),
      null,
    ),
  );
  test(
    'precise and cycle aliases retain upstream precedence',
    () => equal(
      total(
        paid: [
          {
            'ResourceId': 'r',
            'PackageCode': 'pack',
            'CapacityRemainPrecise': 2.5,
            'CapacityRemain': 2,
            'CycleCapacityRemain': 10,
          },
        ],
      ),
      2.5,
    ),
  );
  test(
    'invalid precise may use another valid explicit remaining alias',
    () => equal(
      total(
        paid: [
          {
            'ResourceId': 'r',
            'PackageCode': 'pack',
            'CapacityRemainPrecise': 'bad',
            'CycleRemainCapacity': '3.5',
          },
        ],
      ),
      3.5,
    ),
  );
  test(
    'lowercase identity and expiry aliases share normalization',
    () => equal(
      total(
        paid: [
          {
            'resourceId': 'r',
            'packageCode': 'pack',
            'CapacityRemain': 5,
            'expiredTime': '2027-01-15T00:00:00Z',
          },
        ],
      ),
      0.0,
    ),
  );
  test(
    'cycle-only expiry is honored',
    () => equal(
      total(
        paid: [
          {...resource('r', 5), 'cycleEndTime': '2027-01-15T00:00:00Z'},
        ],
      ),
      0.0,
    ),
  );
  for (final value in [
    double.nan,
    double.infinity,
    -1,
    'NaN',
    'Infinity',
    '-1',
    '',
    'not-a-number',
    true,
    <String, Object?>{},
  ]) {
    test(
      'invalid remaining ${value.runtimeType}: $value is unknown',
      () => equal(total(paid: [resource('r', value)]), null),
    );
  }
  test(
    'overflowed aggregate remains unknown',
    () => equal(
      total(paid: [resource('r1', 1.7e308), resource('r2', 1.7e308)]),
      null,
    ),
  );
  test(
    'slice capacities are not added',
    () => equal(
      total(
        paid: [
          {...resource('slice', 900), 'CapacityType': 4},
          resource('r', 5),
        ],
      ),
      5.0,
    ),
  );
  test('non-object rows are not ignored', () => equal(total(paid: [5]), null));
  test(
    'expired unknown package cannot poison active known balance',
    () => equal(
      total(
        paid: [
          resource('old', null, expiry: '2027-01-14T00:00:00Z'),
          resource('r', 5),
        ],
      ),
      5.0,
    ),
  );
  test(
    'expiry equal to observation is expired',
    () => equal(
      total(paid: [resource('r', 5, expiry: '2027-01-15T00:00:00Z')]),
      0.0,
    ),
  );
  test(
    'timezone-less expiry is China time',
    () => equal(
      total(paid: [resource('r', 5, expiry: '2027-01-15 08:00:00')]),
      0.0,
    ),
  );
  test(
    'date-only expiry is China end-of-day',
    () => equal(
      total(
        paid: [resource('r', 5, expiry: '2027-01-15')],
        at: DateTime.utc(2027, 1, 15, 15, 59, 58),
      ),
      5.0,
    ),
  );
  test(
    'date-only expiry exact China end is expired',
    () => equal(
      total(
        paid: [resource('r', 5, expiry: '2027-01-15')],
        at: DateTime.utc(2027, 1, 15, 15, 59, 59),
      ),
      0.0,
    ),
  );
  test(
    'RFC3339 offset is respected',
    () => equal(
      total(paid: [resource('r', 5, expiry: '2027-01-15T08:00:00+08:00')]),
      0.0,
    ),
  );
  test('numeric seconds and milliseconds describe same boundary', () {
    equal(total(paid: [resource('r', 5, expiry: 1799971200)]), 0.0);
    equal(total(paid: [resource('r', 5, expiry: 1799971200000)]), 0.0);
  });
  test(
    'far-future deduction placeholder uses cycle boundary',
    () => equal(
      total(
        paid: [
          {
            ...resource('r', 5, expiry: '2049-01-01 00:00:00'),
            'CycleEndTime': '2027-01-15 08:00:00',
          },
        ],
      ),
      0.0,
    ),
  );
  test(
    'nearer deduction expiry remains authoritative',
    () => equal(
      total(
        paid: [
          {
            ...resource('r', 5, expiry: '2027-01-16 08:00:00'),
            'CycleEndTime': '2027-01-15 08:00:00',
          },
        ],
      ),
      5.0,
    ),
  );
  for (final invalid in [
    'bad-date',
    '2027-02-30',
    '2027-01-15 25:00:00',
    '2027-01-15T08:00:00+25:00',
    0,
    -1,
    double.infinity,
  ]) {
    test(
      'malformed explicit expiry $invalid remains unknown',
      () => equal(total(paid: [resource('r', 5, expiry: invalid)]), null),
    );
  }
  test(
    'missing expiry retains pinned active semantics',
    () => equal(total(paid: [resource('r', 5)]), 5.0),
  );
  final emptySummary = response('Packages', []),
      empty = response('Accounts', []);
  test(
    'failed branch prevents total',
    () => equal(
      normalizeWorkBuddyBalance(emptySummary, empty, {'code': 401}, now: now),
      null,
    ),
  );
  test(
    'missing branch prevents total',
    () => equal(
      normalizeWorkBuddyBalance(emptySummary, empty, {}, now: now),
      null,
    ),
  );
  test(
    'TotalCount larger than page prevents partial total',
    () => equal(
      normalizeWorkBuddyBalance(
        emptySummary,
        response('Accounts', [resource('r', 5)], count: 2),
        empty,
        now: now,
      ),
      null,
    ),
  );
  test(
    'invalid TotalCount does not use short-page fallback',
    () => equal(
      normalizeWorkBuddyBalance(
        emptySummary,
        response('Accounts', [resource('r', 5)], count: 'NaN'),
        empty,
        now: now,
      ),
      null,
    ),
  );
  test(
    'null TotalCount is not an absent count',
    () => equal(
      normalizeWorkBuddyBalance(
        emptySummary,
        {
          'code': 0,
          'data': {
            'Accounts': [resource('r', 5)],
            'TotalCount': null,
          },
        },
        empty,
        now: now,
      ),
      null,
    ),
  );
  test(
    'fractional TotalCount cannot prove page completion',
    () => equal(
      normalizeWorkBuddyBalance(
        emptySummary,
        response('Accounts', [resource('r', 5)], count: 1.5),
        empty,
        now: now,
      ),
      null,
    ),
  );
  test(
    'full page without count cannot prove completion',
    () => equal(
      normalizeWorkBuddyBalance(
        emptySummary,
        response(
          'Accounts',
          List.generate(200, (i) => resource('r$i', 1)),
          includeCount: false,
        ),
        empty,
        now: now,
      ),
      null,
    ),
  );
  test(
    'full page with matching count is complete',
    () => equal(
      normalizeWorkBuddyBalance(
        emptySummary,
        response('Accounts', List.generate(200, (i) => resource('r$i', 1))),
        empty,
        now: now,
      ),
      200.0,
    ),
  );
  test(
    'short page without count follows pinned contract',
    () => equal(
      normalizeWorkBuddyBalance(
        emptySummary,
        response('Accounts', [resource('r', 5)], includeCount: false),
        empty,
        now: now,
      ),
      5.0,
    ),
  );
  test(
    'deepest nested count must be complete',
    () => equal(
      normalizeWorkBuddyBalance(
        emptySummary,
        {
          'code': 0,
          'data': {
            'data': {
              'Response': {
                'Data': {
                  'Accounts': [resource('r', 5)],
                  'TotalCount': 2,
                },
              },
            },
          },
        },
        empty,
        now: now,
      ),
      null,
    ),
  );
  test(
    'supported nested response and lowercase arrays',
    () => equal(
      normalizeWorkBuddyBalance(
        {
          'code': '200',
          'data': {
            'Response': {
              'Data': {'packages': [], 'totalCount': '0'},
            },
          },
        },
        {
          'code': '0',
          'data': {
            'data': {
              'accounts': [resource('r', 5)],
              'totalCount': '1',
            },
          },
        },
        empty,
        now: now,
      ),
      5.0,
    ),
  );
  test(
    'conflicting count aliases are unknown',
    () => equal(
      normalizeWorkBuddyBalance(
        emptySummary,
        {
          'code': 0,
          'data': {
            'Accounts': [resource('r', 5)],
            'TotalCount': 1,
            'totalCount': 2,
          },
        },
        empty,
        now: now,
      ),
      null,
    ),
  );
  test(
    'conflicting row aliases are unknown',
    () => equal(
      normalizeWorkBuddyBalance(
        emptySummary,
        {
          'code': 0,
          'data': {
            'Accounts': [resource('r', 5)],
            'accounts': [],
            'TotalCount': 1,
          },
        },
        empty,
        now: now,
      ),
      null,
    ),
  );
  test(
    'conflicting response containers are unknown',
    () => equal(
      normalizeWorkBuddyBalance(
        emptySummary,
        {
          'code': 0,
          'data': {
            'Accounts': [resource('r', 5)],
            'TotalCount': 1,
            'data': {'Accounts': [], 'TotalCount': 0},
          },
        },
        empty,
        now: now,
      ),
      null,
    ),
  );
  test(
    'identical alias arrays and counts are not treated as conflict',
    () => equal(
      normalizeWorkBuddyBalance(
        emptySummary,
        {
          'code': 0,
          'data': {
            'Accounts': [resource('r', 5)],
            'accounts': [resource('r', 5)],
            'TotalCount': 1,
            'totalCount': '1',
          },
        },
        empty,
        now: now,
      ),
      5.0,
    ),
  );
  print('$passed passed; $failed failed');
  if (failed != 0) throw StateError('WorkBuddy balance checks failed');
}
