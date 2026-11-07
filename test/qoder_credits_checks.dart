import '../lib/qoder_credits.dart';

void main() {
  final now = DateTime.utc(2026, 11, 6),
      early = DateTime.utc(2026, 11, 10).millisecondsSinceEpoch;
  final result = normalizeQoderCredits({
    'displayMode': 'qoder',
    'qoderUsage': {
      'expiresAt': DateTime.utc(2026, 11, 7).millisecondsSinceEpoch,
      'userQuota': {'total': 2000, 'used': 500},
      'addOnQuota': {'total': 300, 'used': 50},
      'dedicatedResourcePackages': [
        {'id': 'a', 'available': true, 'remaining': 60, 'expiresAt': early},
        {
          'id': 'b',
          'available': true,
          'remaining': 40,
          'expires_at': early ~/ 1000,
        },
        {
          'id': 'old',
          'available': true,
          'remaining': 999,
          'expiresAt': now.millisecondsSinceEpoch - 1,
        },
        {
          'id': 'disabled',
          'available': false,
          'remaining': 200,
          'expiresAt': early,
        },
        {'id': 'unknown', 'available': true, 'remaining': 20},
      ],
    },
  }, now);
  if (result.planRemaining != 1500 ||
      result.addOnRemaining != 250 ||
      result.packages.totalRemaining != null ||
      result.packages.expiring.single.remaining != 100 ||
      result.packages.expiring.single.expiresAt.millisecondsSinceEpoch !=
          early ||
      result.packages.withoutExpiry != 20)
    throw StateError('Quota overlap, renewal or package expiry confused');
  print(
    'PASS Qoder separate quotas, partial packages, expiry units and remaining amounts',
  );
  final official = normalizeQoderCredits({
    'displayMode': 'qoder',
    'qoderUsage': {
      'userQuota': {'total': 100, 'used': 5, 'remaining': 70},
      'addOnQuota': {'cap': 50, 'remaining': 40},
      'dedicatedResourcePackages': [
        {'remaining': 125, 'expiresAt': '2026-11-10T08:00:00+08:00'},
        {'remaining': 20, 'expiresAt': 253402214400000},
      ],
    },
  }, now);
  if (official.planRemaining != 70 ||
      official.addOnRemaining != 40 ||
      official.packages.expiring.single.remaining != 125 ||
      official.packages.expiring.single.expiresAt !=
          DateTime.utc(2026, 11, 10) ||
      official.packages.withoutExpiry != 20 ||
      official.packages.totalRemaining != null)
    throw StateError('Official remaining, ISO expiry or sentinel misread');
  print(
    'PASS Qoder official remaining and ISO package dates without availability flags',
  );
}
