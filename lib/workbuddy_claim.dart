// Adapted from SailingLoong/LoongPort 9e1b7e574e1ca923d8ee5aab3cd7ede16a8872b6
// workbuddy/{checkin,engine,protocol,model}.rs (MIT).
// Copyright (c) 2025 Jason Young; Copyright (c) 2026 SailingLoong.
// checkin parsing originally adapted from workbuddy-switch (c) 2026 wb-switch.
import 'dart:convert';

enum WorkBuddyState {
  unconfirmed,
  available,
  claimed,
  alreadyClaimed,
  unavailable,
  needsVerification,
}

class WorkBuddyFailure implements Exception {
  final String code;
  const WorkBuddyFailure(this.code);
  @override
  String toString() => code;
}

class WorkBuddySubject {
  final String domain, uid, generation;
  WorkBuddySubject(this.domain, this.uid, this.generation) {
    if (!['www.workbuddy.cn', 'www.codebuddy.cn'].contains(domain) ||
        uid.isEmpty ||
        uid.length > 256 ||
        generation.isEmpty ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(uid)) {
      throw const WorkBuddyFailure('UnsupportedSubject');
    }
  }
  String get key => jsonEncode([domain, uid]);
  bool matches(WorkBuddySubject other) =>
      key == other.key && generation == other.generation;
}

/// From one authenticated observation. Balance must be a complete normalized
/// total, not a partial package sum. This object itself proves no authentication.
class WorkBuddyObservation {
  final WorkBuddySubject subject;
  final Map<String, Object?> status;
  final double? totalRemaining;
  WorkBuddyObservation(
    this.subject,
    Map<String, Object?> status,
    this.totalRemaining,
  ) : status = Map.unmodifiable(status);
}

class WorkBuddyAttempt {
  final int revision;
  final WorkBuddySubject subject;
  final String day;
  final double before;
  final WorkBuddyState receipt;
  final double? expected;
  final WorkBuddyState settled;
  final double? credited;
  const WorkBuddyAttempt({
    required this.revision,
    required this.subject,
    required this.day,
    required this.before,
    this.receipt = WorkBuddyState.unconfirmed,
    this.expected,
    this.settled = WorkBuddyState.unconfirmed,
    this.credited,
  });
}

abstract interface class WorkBuddyAttemptStore {
  Future<WorkBuddyAttempt?> read(String subjectKey);

  /// Must durably commit iff the revision still matches (null means absent).
  /// Return true only after durable commit; exceptions/false never permit send.
  Future<bool> compareAndSet(
    String subjectKey,
    int? expectedRevision,
    WorkBuddyAttempt next,
  );
}

abstract interface class WorkBuddyAttemptHistory {
  Future<WorkBuddyAttempt?> latestSuccessful(String subjectKey);
}

class WorkBuddyResult {
  final WorkBuddyState state;
  final double? credited;
  const WorkBuddyResult(this.state, [this.credited]);
}

abstract interface class WorkBuddyTransport {
  Future<WorkBuddyObservation> observe(WorkBuddySubject subject);

  /// Exactly one request; implementation MUST NOT redirect or retry.
  Future<Map<String, Object?>> claim(WorkBuddySubject subject);
}

class WorkBuddyProtocol {
  static int? _code(Map<String, Object?> body) {
    final value = body['code'];
    return value is int
        ? value
        : value is String
        ? int.tryParse(value)
        : null;
  }

  static bool _success(Map<String, Object?> body) =>
      [0, 200].contains(_code(body));
  static WorkBuddyState _error(Map<String, Object?> body) =>
      switch (_code(body)) {
        401 || 403 || 10085 => WorkBuddyState.needsVerification,
        1001 => WorkBuddyState.alreadyClaimed,
        1002 || 1003 => WorkBuddyState.unavailable,
        _ => WorkBuddyState.unconfirmed,
      };
  static WorkBuddyState status(Map<String, Object?> body) {
    if (!_success(body)) return _error(body);
    final data = body['data'];
    if (data is! Map) return WorkBuddyState.unconfirmed;
    final checked = data.containsKey('today_checked_in')
        ? data['today_checked_in']
        : data['todayCheckedIn'];
    if (checked == true) return WorkBuddyState.alreadyClaimed;
    if (checked == false && data['active'] == true)
      return WorkBuddyState.available;
    if (checked == false && data['active'] == false)
      return WorkBuddyState.unavailable;
    return WorkBuddyState.unconfirmed;
  }

  static WorkBuddyState receipt(Map<String, Object?> body) =>
      _success(body) ? WorkBuddyState.claimed : _error(body);
  static double? _number(Object? raw) {
    final n = raw is num
        ? raw.toDouble()
        : raw is String
        ? double.tryParse(raw.trim())
        : null;
    return n != null && n.isFinite && n >= 0 ? n : null;
  }

  static double? credit(Map<String, Object?> body) {
    final data = body['data'];
    return _number(
      body.containsKey('credit')
          ? body['credit']
          : data is Map
          ? data['credit']
          : null,
    );
  }

  static WorkBuddyResult reconcile(
    WorkBuddyState receipt,
    WorkBuddyState after,
    double? before,
    double? balance,
    double? credit,
  ) {
    if (receipt == WorkBuddyState.alreadyClaimed &&
        after == WorkBuddyState.alreadyClaimed) {
      return const WorkBuddyResult(WorkBuddyState.alreadyClaimed);
    }
    if (receipt == WorkBuddyState.needsVerification ||
        receipt == WorkBuddyState.unavailable)
      return WorkBuddyResult(receipt);
    if (receipt == WorkBuddyState.claimed &&
        after == WorkBuddyState.alreadyClaimed &&
        _number(before) != null &&
        _number(balance) != null &&
        _number(credit) != null &&
        credit! > 0 &&
        balance! - before! >= credit - 0.000001) {
      return WorkBuddyResult(WorkBuddyState.claimed, credit);
    }
    return const WorkBuddyResult(WorkBuddyState.unconfirmed);
  }
}

/// Executable manual transaction only. Authentication, complete balance
/// normalization and durable CAS storage are supplied by existing owners.
/// No credential is accepted/stored here and no production gateway is created.
class WorkBuddyClaimCore {
  final WorkBuddyAttemptStore store;
  final WorkBuddyTransport transport;
  final DateTime Function() now;

  /// Synchronous owner/lifecycle gate; must be false after cancellation,
  /// logout, credential retirement or ownership change. This does not itself
  /// authenticate credentials; transport must enforce the same gate at the
  /// actual send boundary if it performs any asynchronous setup before sending.
  final bool Function(WorkBuddySubject) isCurrent;
  WorkBuddyClaimCore(
    this.store,
    this.transport,
    this.now, {
    required this.isCurrent,
  });
  void _requireCurrent(WorkBuddySubject subject) {
    if (!isCurrent(subject))
      throw const WorkBuddyFailure('ExpiredAuthorization');
  }

  String _day() => now()
      .toUtc()
      .add(const Duration(hours: 8))
      .toIso8601String()
      .substring(0, 10);
  static const _unknown = WorkBuddyResult(WorkBuddyState.unconfirmed);
  bool _settled(WorkBuddyState value) =>
      value == WorkBuddyState.claimed ||
      value == WorkBuddyState.alreadyClaimed ||
      value == WorkBuddyState.unavailable ||
      value == WorkBuddyState.needsVerification;
  Future<WorkBuddyObservation> _observe(WorkBuddySubject subject) async {
    _requireCurrent(subject);
    final observation = await transport.observe(subject);
    _requireCurrent(subject);
    if (!subject.matches(observation.subject))
      throw const WorkBuddyFailure('IdentityMismatch');
    return observation;
  }

  Future<WorkBuddyResult> _recover(WorkBuddyAttempt attempt) async {
    // Today's observation cannot resolve an older unknown write.
    if (attempt.day != _day()) return _unknown;
    WorkBuddyObservation observed;
    try {
      observed = await _observe(attempt.subject);
    } catch (_) {
      return _unknown;
    }
    if (attempt.day != _day()) return _unknown;
    _requireCurrent(attempt.subject);
    final after = WorkBuddyProtocol.status(observed.status);
    final result = WorkBuddyProtocol.reconcile(
      attempt.receipt,
      after,
      attempt.before,
      observed.totalRemaining,
      attempt.expected,
    );
    if (result.state == WorkBuddyState.unconfirmed &&
        after == WorkBuddyState.needsVerification) {
      return const WorkBuddyResult(WorkBuddyState.needsVerification);
    }
    // No receipt evidence: preserve the original intent and do not mint a
    // replacement revision or infer that an unrelated balance increase was ours.
    if (!_settled(result.state)) return _unknown;
    final next = WorkBuddyAttempt(
      revision: attempt.revision + 1,
      subject: attempt.subject,
      day: attempt.day,
      before: attempt.before,
      receipt: attempt.receipt,
      expected: attempt.expected,
      settled: result.state,
      credited: result.credited,
    );
    if (!await store.compareAndSet(attempt.subject.key, attempt.revision, next))
      return _unknown;
    _requireCurrent(attempt.subject);
    if (attempt.day != _day()) return _unknown;
    return result;
  }

  Future<WorkBuddyResult> claim(WorkBuddySubject subject) async {
    _requireCurrent(subject);
    final day = _day();
    final previous = await store.read(subject.key);
    _requireCurrent(subject);
    if (_day() != day) return _unknown;
    if (previous != null) {
      if (!previous.subject.matches(subject) && !_settled(previous.settled))
        throw const WorkBuddyFailure('GenerationChanged');
      if (!_settled(previous.settled)) return _recover(previous);
      if (previous.day.compareTo(day) >= 0) {
        return WorkBuddyResult(
          previous.settled == WorkBuddyState.claimed
              ? WorkBuddyState.alreadyClaimed
              : previous.settled,
        );
      }
    }
    final observed = await _observe(subject);
    if (_day() != day) return _unknown;
    final eligibility = WorkBuddyProtocol.status(observed.status);
    if (eligibility != WorkBuddyState.available)
      return WorkBuddyResult(eligibility);
    final before = WorkBuddyProtocol._number(observed.totalRemaining);
    if (before == null) return _unknown;
    final intent = WorkBuddyAttempt(
      revision: (previous?.revision ?? -1) + 1,
      subject: subject,
      day: day,
      before: before,
    );
    _requireCurrent(subject);
    if (!await store.compareAndSet(subject.key, previous?.revision, intent))
      return _unknown;
    // Fail closed if ownership or day changed while durable intent was written.
    final admitted = await store.read(subject.key);
    if (_day() != day ||
        admitted == null ||
        admitted.revision != intent.revision ||
        !admitted.subject.matches(subject))
      return _unknown;
    _requireCurrent(subject);
    Map<String, Object?> response;
    try {
      response = await transport.claim(subject);
    } catch (_) {
      // An exception is not evidence that the POST was unsent. No retry.
      return _recover(intent);
    }
    _requireCurrent(subject);
    final receipt = WorkBuddyAttempt(
      revision: intent.revision + 1,
      subject: subject,
      day: day,
      before: before,
      receipt: WorkBuddyProtocol.receipt(response),
      expected: WorkBuddyProtocol.credit(response),
    );
    if (!await store.compareAndSet(subject.key, intent.revision, receipt))
      return _unknown;
    return _recover(receipt);
  }
}
