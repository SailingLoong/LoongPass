import '../credit_summary.dart';

/// Platform protocol owns credentials and official identity; the account owner
/// owns persistence, exclusion, the daily intent journal and task scheduling.
abstract interface class RewardProvider {
  String get id;
  String get label;
  String get region;
  String get regionCode;
  RewardLoginKind get loginKind;
  Set<String> get hosts;
  Future<RewardLogin> beginLogin(RewardTransport http, {String? phone});
  Future<RewardSession> refresh(RewardTransport http, RewardSession session);
  Future<CreditSummary> credits(RewardTransport http, RewardSession session);
  Future<RewardOffer> inspect(
    RewardTransport http,
    RewardSession session,
    String day,
  );
  Future<RewardResult> claim(
    RewardTransport http,
    RewardSession session,
    RewardOffer offer,
    String day,
  );
}

enum RewardLoginKind { browser, sms }

abstract interface class RewardLogin {
  Uri? get url;
  Future<RewardSession?> poll({String? verificationCode});
  void cancel();
}

class RewardSession {
  RewardSession({
    required this.identity,
    required this.label,
    required Map<String, dynamic> credentials,
  }) : credentials = Map.unmodifiable(credentials);
  final String identity, label;
  final Map<String, dynamic> credentials;
  @override
  String toString() => 'RewardSession(redacted)';
}

enum RewardState { available, claimed, already, unavailable }

class RewardOffer {
  RewardOffer(this.state, {Map<String, dynamic> data = const {}})
    : data = Map.unmodifiable(data);
  final RewardState state;
  final Map<String, dynamic> data;
  @override
  String toString() => 'RewardOffer(redacted)';
}

class RewardResult {
  const RewardResult(this.state, {this.amount});
  final RewardState state;
  final double? amount;
}

abstract interface class RewardTransport {
  Future<RewardReply> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Object? body,
  });
}

class RewardReply {
  const RewardReply(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
  @override
  String toString() => 'RewardReply($status, redacted)';
}

class RewardFailure implements Exception {
  const RewardFailure(this.code);
  final String code;
  @override
  String toString() => 'RewardFailure($code)';
}

/// The adapter has explicit evidence that this write was not applied. Unlike
/// an ambiguous transport/response failure, it may safely be attempted again.
class RewardRejected extends RewardFailure {
  const RewardRejected(super.code);
}

/// Business days for these reward services are explicitly Asia/Shanghai.
String rewardDay(DateTime now) => now
    .toUtc()
    .add(const Duration(hours: 8))
    .toIso8601String()
    .substring(0, 10);
