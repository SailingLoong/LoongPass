import 'dart:async';
import 'dart:convert';
import '../lib/account_document_store.dart';
import '../lib/credit_summary.dart';
import '../lib/rewards/reward_provider.dart';

class MemoryStore implements AccountDocumentStore {
  int revision = 0;
  Map<String, dynamic> value = {};
  bool failWrites = false;
  @override
  String get identity => 'isolated-test-rewards';
  @override
  Future<AccountDocument> read() async => AccountDocument(
    revision,
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>,
  );
  @override
  Future<void> write(int expectedRevision, Map<String, dynamic> data) async {
    if (failWrites || expectedRevision != revision)
      throw StateError('unavailable');
    value = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
    revision++;
  }
}

class NoNetwork implements RewardTransport {
  @override
  Future<RewardReply> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Object? body,
  }) async => throw StateError('no real network in account tests');
}

class Login implements RewardLogin {
  Login(this.session);
  RewardSession? session;
  Completer<RewardSession?>? wait;
  bool cancelled = false;
  @override
  Uri? get url => Uri.https('login.example.test', '/authorize');
  @override
  Future<RewardSession?> poll({String? verificationCode}) async =>
      wait == null ? session : await wait!.future;
  @override
  void cancel() => cancelled = true;
}

class Provider implements RewardProvider {
  Provider(this.id);
  @override
  final String id;
  @override
  String get label => 'Test provider';
  @override
  String get region => '国内版';
  @override
  String get regionCode => 'CN';
  @override
  Set<String> get hosts => {'api.example.test'};
  @override
  RewardLoginKind get loginKind => RewardLoginKind.browser;
  String identity = 'official-user-1';
  String token = 'synthetic-token-1';
  RewardState inspected = RewardState.available;
  double amount = 100;
  int claims = 0, reads = 0;
  bool loseReply = false;
  bool failBalance = false;
  bool rejectClaim = false;
  Login? login;
  Completer<void>? claimGate;
  @override
  Future<RewardLogin> beginLogin(RewardTransport http, {String? phone}) async =>
      login ??= Login(
        RewardSession(
          identity: identity,
          label: 'Test account',
          credentials: {'token': token},
        ),
      );
  @override
  Future<RewardSession> refresh(
    RewardTransport http,
    RewardSession session,
  ) async => session;
  @override
  Future<CreditSummary> credits(
    RewardTransport http,
    RewardSession session,
  ) async {
    reads++;
    if (failBalance) throw const RewardFailure('authorization_required');
    return CreditSummary(125.5, 25.5, DateTime.utc(2026, 11, 7), [
      CreditExpiry(DateTime.utc(2026, 12, 1), 100),
    ]);
  }

  @override
  Future<RewardOffer> inspect(
    RewardTransport http,
    RewardSession session,
    String day,
  ) async {
    reads++;
    return RewardOffer(inspected);
  }

  @override
  Future<RewardResult> claim(
    RewardTransport http,
    RewardSession session,
    RewardOffer offer,
    String day,
  ) async {
    claims++;
    if (rejectClaim) throw const RewardRejected('login_required');
    if (claimGate != null) await claimGate!.future;
    if (loseReply) throw const RewardFailure('network_unavailable');
    return RewardResult(RewardState.claimed, amount: amount);
  }
}
