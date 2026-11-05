import 'package:flutter/foundation.dart';
import 'qoder_claim.dart';
import 'qoder_journal.dart';
import 'qoder_pat_import.dart';

/// Integration contract, not proof by construction. A real gateway must obtain
/// the current source/claim authorization, authenticate this exact candidate and
/// verify official-device provenance before returning a fresh bound response.
/// No production gateway exists in this build; tests inject synthetic callbacks.
class QoderSession {
  final QoderReply listing;
  final Future<QoderReply> Function(QoderRequest) exchange;
  const QoderSession(this.listing, this.exchange);
}

class QoderAccountView {
  final String providerId, status;
  const QoderAccountView(this.providerId, this.status);
}

class _Entry {
  final QoderPatCandidate candidate;
  String status = 'unverified';
  bool busy = false;
  _Entry(this.candidate);
}

/// Small in-memory account list. Only the existing non-secret journal persists.
/// Re-import cannot import permissions, authentication or erase attempt history.
class QoderAccountFlow extends ChangeNotifier {
  final Future<QoderSession> Function(QoderPatCandidate)? authenticate;
  final Future<QoderAttemptJournal> Function() openJournal;
  final _entries = <String, _Entry>{};
  bool _closed = false;
  QoderAccountFlow({this.authenticate, required this.openJournal});

  List<QoderAccountView> get accounts => List.unmodifiable([
    for (final e in _entries.entries) QoderAccountView(e.key, e.value.status),
  ]);
  bool get busy => _entries.values.any((e) => e.busy);
  bool canClaim(String id) =>
      !_closed && authenticate != null && _entries.containsKey(id) && !busy;

  void put(QoderPatCandidate candidate) {
    if (_closed) throw const QoderFailure('AccountFlowClosed');
    if (_entries[candidate.providerId]?.busy == true)
      throw const QoderFailure('AccountBusy');
    _entries[candidate.providerId] = _Entry(candidate);
    notifyListeners();
  }

  Future<void> claim(String id) async {
    final entry = _entries[id];
    if (_closed || entry == null || busy) return;
    final gateway = authenticate;
    if (gateway == null) {
      entry.status = 'unavailable';
      notifyListeners();
      return;
    }
    entry.busy = true;
    entry.status = 'checking';
    notifyListeners();
    var phase = 'authentication';
    try {
      final session = await gateway(entry.candidate);
      if (_closed) return;
      if (session.listing.identity.providerId != id ||
          session.listing.identity.region != 'international')
        throw const QoderFailure('IdentityMismatch');
      phase = 'storage';
      final journal = await openJournal();
      if (_closed) return;
      phase = 'operation';
      final result = await journal.perform(session.listing, (request) async {
        // An intent may already be durable. Closing the page never grants a new
        // send; retain that intent so a future owner can only reconcile by GET.
        if (_closed) throw const QoderFailure('AccountFlowClosed');
        return session.exchange(request);
      });
      entry.status = switch (result) {
        QoderOutcome.newlyClaimed => 'claimed',
        QoderOutcome.alreadyClaimed => 'already',
        QoderOutcome.claimedDeltaUnknown => 'confirmed',
        QoderOutcome.verificationRequired => 'verification',
        QoderOutcome.rateLimited => 'limited',
        QoderOutcome.unknown || QoderOutcome.conflict => 'unknown',
      };
    } catch (error) {
      final code = error is QoderFailure ? error.code : '';
      entry.status = phase == 'authentication' || code == 'IdentityMismatch'
          ? 'verification'
          : phase == 'storage' ||
                code.startsWith('Journal') ||
                code == 'PersistenceUnavailable'
          ? 'blocked'
          : code == 'NoEligibleCampaign' || code == 'CampaignWindowClosed'
          ? 'ineligible'
          : 'unknown';
    } finally {
      entry.busy = false;
      if (!_closed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _entries.clear();
    super.dispose();
  }
}
