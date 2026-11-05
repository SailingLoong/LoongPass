import '../lib/zcode_native.dart';
import '../lib/zcode_promotions.dart';

void check(bool condition, String label) {
  if (!condition) throw StateError(label);
}

Map<String, Object?> view({String status = 'claimable', bool canClaim = true}) => {
  'status': status,
  'canClaim': canClaim,
  'planId': 'midnight-plan',
  'planName': '半夜活动',
  'reason': null,
  'startsAt': 1793808000,
  'endsAt': 1793811600,
  'checkedAt': 1793808300,
  'windowPolicy': 'serverPreview',
  'exactOfferWindow': null,
};

Future<void> main() async {
  final id = 'a' * 64;
  final calls = <String>[];
  final arguments = <Map<String, Object?>>[];
  Object? reply = {'available': true, 'reason': null};
  final client = ZcodePromotionsClient(call: (method, args) async {
    calls.add(method);
    arguments.add(args);
    return reply;
  });
  check(calls.isEmpty, 'construction performs no I/O');
  check((await client.status()).available, 'status decoded');
  check(calls.single == 'promotionStatus' && arguments.single.isEmpty,
      'status wire contract');
  reply = view();
  final preview = await client.preview(id);
  check(preview.status == 'claimable' && preview.canClaim &&
      preview.startsAt == 1793808000 && preview.exactOfferWindow == null &&
      preview.windowPolicy == 'serverPreview', 'server-only seconds window');
  check(calls.last == 'previewPromotions' &&
      arguments.last.length == 1 && arguments.last['accountId'] == id,
      'preview exposes opaque account handle only');
  reply = view(status: 'claimed', canClaim: false);
  check((await client.claim(id, automatic: true)).status == 'claimed',
      'claim receipt decoded');
  check(calls.last == 'claimPromotions' && arguments.last.length == 2 &&
      arguments.last['automatic'] == true, 'automatic intent reaches native');

  for (final bad in <Object?>[
    null,
    {'status': 'surprise', 'canClaim': true},
    {...view(), 'accessToken': 'never-display'},
    {...view(), 'windowPolicy': 'localDay'},
    {...view(), 'exactOfferWindow': 3},
    {...view(), 'canClaim': 'true'},
    {...view(), 'status': 'claimed', 'canClaim': true},
    {...view(), 'planId': null},
    {...view(status: 'resultPending', canClaim: false), 'planId': null},
    {...view(), 'startsAt': -1},
    {...view(), 'checkedAt': 1793808300000},
    {...view(), 'planName': 'unsafe\nlabel'},
  ]) {
    reply = bad;
    final result = await client.claim(id);
    check(result.status == 'unknown' && !result.canClaim &&
        result.reason == 'InvalidReply', 'malformed claim is unknown');
  }
  reply = {...view(), 'reason': 'raw secret text'};
  check((await client.preview(id)).reason == 'NativeFailure',
      'raw reasons never cross boundary');
  reply = {...view(), 'reason': 'notDue'};
  check((await client.preview(id)).reason == 'notDue',
      'safe promotion reason retains native meaning');
  reply = {'status': 'unknown', 'canClaim': false, 'planId': null,
    'planName': null, 'reason': 'confirmResult', 'startsAt': null,
    'endsAt': null, 'checkedAt': null, 'windowPolicy': 'serverPreview',
    'exactOfferWindow': null};
  final fallback = await client.claim(id);
  check(fallback.status == 'unknown' && !fallback.canClaim &&
      fallback.planId == null && fallback.reason == 'confirmResult',
      'exact Swift unknown fallback does not pretend a native pending record exists');
  var rejected = false;
  final count = calls.length;
  try { await client.preview('not-a-handle'); }
  on ZcodeNativeFailure catch (e) { rejected = e.code == 'InvalidArguments'; }
  check(rejected && calls.length == count, 'bad account rejected before call');
  final disconnected = ZcodePromotionsClient(call: (_, _) async {
    throw StateError('private token /Users/private/path');
  });
  final unknown = await disconnected.claim(id);
  check(unknown.status == 'unknown' && !unknown.canClaim &&
      unknown.reason == 'NativeUnavailable', 'transport claim stays unknown');
  final missing = ZcodePromotionsClient(call: (_, _) async {
    throw ZcodeNativeFailure.fromCode('NativeContextUnavailable');
  });
  final unavailable = await missing.status();
  check(!unavailable.available && unavailable.reason == 'NativeContextUnavailable',
      'missing backend fails closed');
  print('PASS ZCode promotion client synthetic contracts and failure cases');
}
