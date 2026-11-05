import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/qoder_claim.dart';

const identity = QoderIdentity(
  'synthetic-provider',
  'synthetic-uid',
  'generation-1',
);
final now = DateTime.utc(2026, 11, 3, 12);
final nowSeconds = now.millisecondsSinceEpoch ~/ 1000;
final listingUri = Uri.parse(
  'https://openapi.qoder.sh/sash/api/v1/me/campaigns?clientType=10',
);
final claimUri = Uri.parse(
  'https://openapi.qoder.sh/sash/api/v1/me/campaigns/synthetic-daily/claim',
);
Map<String, Object?> row() => {
  'campaignId': 'synthetic-daily',
  'campaignKey': 'synthetic-window',
  'actionType': 'CLAIM_BENEFIT',
  'claimStatus': 'CLAIMABLE',
  'startAt': nowSeconds - 100,
  'endAt': nowSeconds + 3600,
  'benefit': {'kind': 'CREDITS', 'amount': 100},
};
QoderReply listing({
  Object? body,
  Uri? uri,
  Map<String, List<String>>? headers,
  QoderIdentity id = identity,
  Duration elapsed = Duration.zero,
}) => QoderReply(
  identity: id,
  uri: uri ?? listingUri,
  status: 200,
  body: jsonEncode(
    body ??
        {
          'uid': identity.uid,
          'campaigns': [row()],
        },
  ),
  headers:
      headers ??
      {
        'Date': [HttpDate.format(now)],
      },
  requestElapsed: elapsed,
);
Map<String, Object?> receipt() => {
  'uid': identity.uid,
  'status': 'CLAIMED',
  'campaignId': 'synthetic-daily',
  'campaignKey': 'synthetic-window',
  'grantId': 'synthetic-grant',
  'claimedAt': now.toIso8601String(),
  'replayed': false,
};
QoderReply reply(
  QoderRequest request, {
  Object? body,
  int status = 200,
  QoderIdentity id = identity,
  Uri? uri,
}) => QoderReply(
  identity: id,
  uri: uri ?? request.uri,
  status: status,
  body: jsonEncode(body ?? receipt()),
);
Matcher fails(String code) =>
    throwsA(isA<QoderFailure>().having((e) => e.code, 'code', code));

void main() {
  test(
    'persists before one exact POST and validates new 100-credit grant',
    () async {
      final op = QoderClaimOperation.prepare(listing());
      final order = <String>[];
      final result = await op.execute(
        identity: identity,
        persistIntent: (record) async {
          order.add('persist');
          expect(record['uid'], identity.uid);
          return true;
        },
        exchange: (request) async {
          order.add('send');
          expect(request.method, 'POST');
          expect(request.uri, claimUri);
          expect(request.body, '{}');
          return reply(request);
        },
      );
      expect(order, ['persist', 'send']);
      expect(result, QoderOutcome.newlyClaimed);
      expect(result.addedCredits, 100);
    },
  );
  test(
    'unknown POST can only be followed by reward GET, never another POST',
    () async {
      final op = QoderClaimOperation.prepare(listing());
      final methods = <String>[];
      var saves = 0;
      Future<QoderOutcome> run() => op.execute(
        identity: identity,
        persistIntent: (_) async {
          saves++;
          return true;
        },
        exchange: (request) async {
          methods.add(request.method);
          if (request.method == 'POST')
            throw const FormatException('SYNTHETIC_SECRET');
          expect(request.uri.path.endsWith('/reward'), true);
          expect(request.body, isNull);
          return reply(request);
        },
      );
      expect(await run(), QoderOutcome.unknown);
      final recovered = await run();
      expect(recovered, QoderOutcome.claimedDeltaUnknown);
      expect(recovered.addedCredits, isNull);
      expect(methods, ['POST', 'GET']);
      expect(saves, 1);
    },
  );
  test(
    'resuming a saved intent only GETs and preserves identity binding',
    () async {
      Map<String, Object?>? saved;
      final op = QoderClaimOperation.prepare(listing());
      await op.execute(
        identity: identity,
        persistIntent: (r) async {
          saved = r;
          return true;
        },
        exchange: (_) async => throw StateError('synthetic timeout'),
      );
      final restored = QoderClaimOperation.resume(saved!, identity);
      expect(
        await restored.execute(
          identity: identity,
          persistIntent: (_) async =>
              throw StateError('must not persist again'),
          exchange: (request) async {
            expect(request.method, 'GET');
            return reply(request);
          },
        ),
        QoderOutcome.claimedDeltaUnknown,
      );
      expect(
        () => QoderClaimOperation.resume(
          saved!,
          const QoderIdentity('synthetic-provider', 'other', 'generation-1'),
        ),
        fails('IdentityMismatch'),
      );
    },
  );
  test(
    'persistence rejection prevents POST and keeps only read recovery',
    () async {
      final op = QoderClaimOperation.prepare(listing());
      var sends = 0;
      expect(
        await op.execute(
          identity: identity,
          persistIntent: (_) async => false,
          exchange: (request) async {
            sends++;
            return reply(request);
          },
        ),
        QoderOutcome.unknown,
      );
      expect(sends, 0);
      await op.execute(
        identity: identity,
        persistIntent: (_) async => throw StateError('not again'),
        exchange: (request) async {
          expect(request.method, 'GET');
          return reply(request);
        },
      );
    },
  );
  test(
    'persistence exception never sends and exposes no underlying content',
    () async {
      final op = QoderClaimOperation.prepare(listing());
      var sends = 0;
      await expectLater(
        op.execute(
          identity: identity,
          persistIntent: (_) async => throw StateError('SYNTHETIC_SECRET'),
          exchange: (r) async {
            sends++;
            return reply(r);
          },
        ),
        fails('PersistenceUnavailable'),
      );
      expect(sends, 0);
    },
  );
  test('concurrent execution has only one writer', () async {
    final op = QoderClaimOperation.prepare(listing());
    final gate = Completer<bool>();
    var sends = 0;
    final first = op.execute(
      identity: identity,
      persistIntent: (_) => gate.future,
      exchange: (r) async {
        sends++;
        return reply(r);
      },
    );
    await expectLater(
      op.execute(
        identity: identity,
        persistIntent: (_) async => true,
        exchange: (r) async => reply(r),
      ),
      fails('Busy'),
    );
    gate.complete(true);
    await first;
    expect(sends, 1);
  });
  test('changed account or generation is blocked before persistence', () async {
    for (final id in [
      const QoderIdentity('synthetic-provider', 'other', 'generation-1'),
      const QoderIdentity(
        'synthetic-provider',
        'synthetic-uid',
        'generation-2',
      ),
    ]) {
      final op = QoderClaimOperation.prepare(listing());
      await expectLater(
        op.execute(
          identity: id,
          persistIntent: (_) async => throw StateError('not called'),
          exchange: (r) async => reply(r),
        ),
        fails('IdentityMismatch'),
      );
    }
  });
  final invalidRows = <String, Object?>{
    'double amount': {
      ...row(),
      'benefit': {'kind': 'CREDITS', 'amount': 100.0},
    },
    'other benefit': {
      ...row(),
      'benefit': {'kind': 'CREDITS', 'amount': 200},
    },
    'claimed': {...row(), 'claimStatus': 'CLAIMED'},
    'unsafe id': {...row(), 'campaignId': '../other'},
    'expired': {...row(), 'endAt': nowSeconds},
    'not started': {...row(), 'startAt': nowSeconds + 100},
    'floating window': {...row(), 'startAt': (nowSeconds - 100).toDouble()},
  };
  for (final entry in invalidRows.entries) {
    test(
      'rejects ${entry.key} without selecting a target',
      () => expect(
        () => QoderClaimOperation.prepare(
          listing(
            body: {
              'uid': identity.uid,
              'campaigns': [entry.value],
            },
          ),
        ),
        fails('NoEligibleCampaign'),
      ),
    );
  }
  test(
    'two eligible campaigns never choose the first',
    () => expect(
      () => QoderClaimOperation.prepare(
        listing(
          body: {
            'uid': identity.uid,
            'campaigns': [
              row(),
              {...row(), 'campaignId': 'second'},
            ],
          },
        ),
      ),
      fails('AmbiguousTarget'),
    ),
  );
  test(
    'conflicting root and data identities are rejected',
    () => expect(
      () => QoderClaimOperation.prepare(
        listing(
          body: {
            'uid': 'other',
            'data': {
              'uid': identity.uid,
              'campaigns': [row()],
            },
          },
        ),
      ),
      fails('IdentityMismatch'),
    ),
  );
  test(
    'both campaign envelopes are ambiguous',
    () => expect(
      () => QoderClaimOperation.prepare(
        listing(
          body: {
            'uid': identity.uid,
            'campaigns': [row()],
            'data': {
              'uid': identity.uid,
              'campaigns': [row()],
            },
          },
        ),
      ),
      fails('InvalidResponse'),
    ),
  );
  test(
    'CN identity is not sent to international origin',
    () => expect(
      () => QoderClaimOperation.prepare(
        listing(id: const QoderIdentity('cn', 'uid', 'gen', region: 'china')),
      ),
      fails('UnsupportedRegion'),
    ),
  );
  final badHeaders = <String, Map<String, List<String>>>{
    'missing Date': {},
    'duplicate Date': {
      'Date': [HttpDate.format(now), HttpDate.format(now)],
    },
    'mixed-case duplicate Date': {
      'Date': [HttpDate.format(now)],
      'date': [HttpDate.format(now)],
    },
    'nonzero Age': {
      'Date': [HttpDate.format(now)],
      'Age': ['1'],
    },
    'duplicate Age': {
      'Date': [HttpDate.format(now)],
      'Age': ['0', '0'],
    },
    'Via': {
      'Date': [HttpDate.format(now)],
      'Via': ['synthetic-proxy'],
    },
    'wrong weekday': {
      'Date': ['Mon, 03 Nov 2026 12:00:00 GMT'],
    },
  };
  for (final entry in badHeaders.entries) {
    test(
      'unverified clock: ${entry.key}',
      () => expect(
        () => QoderClaimOperation.prepare(listing(headers: entry.value)),
        fails('ClockUnverified'),
      ),
    );
  }
  test(
    'slow response is not trusted time',
    () => expect(
      () => QoderClaimOperation.prepare(
        listing(elapsed: const Duration(seconds: 31)),
      ),
      fails('ClockUnverified'),
    ),
  );
  test(
    'wrong origin never supplies trusted campaign metadata',
    () => expect(
      () => QoderClaimOperation.prepare(
        listing(
          uri: Uri.parse(
            'https://other.invalid/sash/api/v1/me/campaigns?clientType=10',
          ),
        ),
      ),
      fails('InvalidResponse'),
    ),
  );
  test('malformed and oversized JSON are rejected', () {
    for (final body in ['{', ' ' * (1024 * 1024 + 1)]) {
      expect(
        () => QoderClaimOperation.prepare(
          QoderReply(
            identity: identity,
            uri: listingUri,
            status: 200,
            body: body,
            headers: {
              'Date': [HttpDate.format(now)],
            },
          ),
        ),
        fails('InvalidResponse'),
      );
    }
  });
  final cases = <String, (int, Object?, QoderOutcome)>{
    'replay': (
      200,
      {...receipt(), 'replayed': true},
      QoderOutcome.alreadyClaimed,
    ),
    'missing replay': (
      200,
      Map<String, Object?>.from(receipt())..remove('replayed'),
      QoderOutcome.claimedDeltaUnknown,
    ),
    'missing grant': (
      200,
      Map<String, Object?>.from(receipt())..remove('grantId'),
      QoderOutcome.unknown,
    ),
    'wrong key': (
      200,
      {...receipt(), 'campaignKey': 'other'},
      QoderOutcome.unknown,
    ),
    'invalid date': (
      200,
      {...receipt(), 'claimedAt': '2026-11-99T12:00:00Z'},
      QoderOutcome.unknown,
    ),
    'missing zone': (
      200,
      {...receipt(), 'claimedAt': '2026-11-03T12:00:00'},
      QoderOutcome.unknown,
    ),
    'expired receipt': (
      200,
      {...receipt(), 'claimedAt': '2020-01-01T00:00:00Z'},
      QoderOutcome.unknown,
    ),
    'wrong uid': (200, {...receipt(), 'uid': 'other'}, QoderOutcome.unknown),
    'service error': (
      200,
      {...receipt(), 'success': false},
      QoderOutcome.unknown,
    ),
    '409 new not proved': (409, receipt(), QoderOutcome.conflict),
    '409 replay': (
      409,
      {...receipt(), 'replayed': true},
      QoderOutcome.alreadyClaimed,
    ),
    '401': (401, {}, QoderOutcome.verificationRequired),
    '403': (403, {}, QoderOutcome.verificationRequired),
    '429': (429, {}, QoderOutcome.rateLimited),
    '503': (503, {}, QoderOutcome.unknown),
  };
  for (final entry in cases.entries) {
    test('receipt ${entry.key}', () async {
      final op = QoderClaimOperation.prepare(listing());
      expect(
        await op.execute(
          identity: identity,
          persistIntent: (_) async => true,
          exchange: (r) async =>
              reply(r, status: entry.value.$1, body: entry.value.$2),
        ),
        entry.value.$3,
      );
    });
  }
  test(
    'external receipt cannot be accepted even if its JSON looks correct',
    () async {
      final op = QoderClaimOperation.prepare(listing());
      expect(
        await op.execute(
          identity: identity,
          persistIntent: (_) async => true,
          exchange: (r) async =>
              reply(r, uri: Uri.parse('https://other.invalid/claim')),
        ),
        QoderOutcome.unknown,
      );
    },
  );
  test(
    'duplicate and escaped duplicate receipt keys are never new grants',
    () async {
      for (final prefix in [
        '"uid":"other",',
        r'"\u0075id":"other",',
        '"status":"FAILED",',
        '"replayed":true,',
      ]) {
        final op = QoderClaimOperation.prepare(listing());
        final body = '{' + prefix + jsonEncode(receipt()).substring(1);
        expect(
          await op.execute(
            identity: identity,
            persistIntent: (_) async => true,
            exchange: (r) async => QoderReply(
              identity: identity,
              uri: r.uri,
              status: 200,
              body: body,
            ),
          ),
          QoderOutcome.unknown,
        );
      }
    },
  );
  test('duplicate listing keys and nested keys are rejected', () {
    for (final body in [
      '{"uid":"other",' +
          jsonEncode({
            'uid': identity.uid,
            'campaigns': [row()],
          }).substring(1),
      jsonEncode({
        'uid': identity.uid,
        'campaigns': [row()],
      }).replaceFirst('"amount":100', '"amount":200,"amount":100'),
    ]) {
      expect(
        () => QoderClaimOperation.prepare(
          QoderReply(
            identity: identity,
            uri: listingUri,
            status: 200,
            body: body,
            headers: {
              'Date': [HttpDate.format(now)],
            },
          ),
        ),
        fails('InvalidResponse'),
      );
    }
  });
  test(
    'large bounded campaign list is scanned without a quadratic re-scan',
    () {
      final rows = [
        for (var i = 0; i < 10000; i++)
          {'campaignId': 'x$i', 'campaignKey': 'y'},
        row(),
      ];
      final response = listing(body: {'uid': identity.uid, 'campaigns': rows});
      final clock = Stopwatch()..start();
      QoderClaimOperation.prepare(response);
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
    },
  );
}
