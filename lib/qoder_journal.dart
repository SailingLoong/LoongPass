// Non-secret append-only owner, adapted from LoongPort's Qoder operation rules.
// No credentials, database, background service or automatic deletion.
import 'dart:convert';
import 'dart:io';
import 'qoder_claim.dart';

const _maxJournal = 16 * 1024 * 1024;
const _recordKeys = {
  'providerId',
  'uid',
  'generation',
  'region',
  'campaignId',
  'campaignKey',
  'startAt',
  'endAt',
};
const _known = {
  QoderOutcome.newlyClaimed,
  QoderOutcome.alreadyClaimed,
  QoderOutcome.claimedDeltaUnknown,
};

class QoderJournalEntry {
  final Map<String, Object?> record;
  final QoderOutcome outcome;
  QoderJournalEntry(Map<String, Object?> record, this.outcome)
    : record = Map.unmodifiable(record);
}

/// Use only from the application's single owning isolate. POSIX advisory locks
/// serialize other processes, not other isolates in this process. All access in
/// this isolate shares the guard below; callers must not open the journal behind
/// this owner. A failed/partial log is blocked, never silently trimmed/replaced.
class QoderAttemptJournal {
  static final _busy = <String>{};
  final Directory root;

  /// Must sync the containing directory hierarchy before acknowledging a write.
  /// The Mac bridge supplies native fsync; tests explicitly supply their seam.
  final Future<void> Function() syncDirectory;
  QoderAttemptJournal(this.root, {required this.syncDirectory});

  Future<bool> claim(Map<String, Object?> record) async {
    final proposed = _record(record);
    return _locked((file, history) async {
      final old = history[_subject(proposed)];
      if (old != null &&
          (old.outcome == QoderOutcome.unknown ||
              _sameCampaign(old.record, proposed) ||
              (proposed['startAt'] as int) < (old.record['endAt'] as int)))
        return false;
      await _append(file, {'kind': 'intent', 'record': proposed});
      return true;
    });
  }

  Future<QoderJournalEntry?> latest(QoderIdentity identity) async => _locked(
    (_, history) async => history[jsonEncode([identity.region, identity.uid])],
  );

  Future<void> complete(
    Map<String, Object?> record,
    QoderOutcome outcome,
  ) async {
    final proposed = _record(record);
    if (!_known.contains(outcome))
      return; // Unknown/verification/rate-limit stay pending.
    await _locked((file, history) async {
      final old = history[_subject(proposed)];
      if (old == null || !_sameRecord(old.record, proposed))
        throw const QoderFailure('JournalConflict');
      if (old.outcome != QoderOutcome.unknown) return;
      await _append(file, {
        'kind': 'settled',
        'record': proposed,
        'outcome': outcome.name,
      });
    });
  }

  Future<QoderOutcome> perform(
    QoderReply listing,
    Future<QoderReply> Function(QoderRequest) exchange,
  ) async {
    final old = await latest(listing.identity);
    if (old != null &&
        old.outcome != QoderOutcome.unknown &&
        QoderClaimOperation.matchesClaimedListing(listing, old.record)) {
      return QoderOutcome.alreadyClaimed;
    }
    final operation = old?.outcome == QoderOutcome.unknown
        ? QoderClaimOperation.resume(old!.record, listing.identity)
        : QoderClaimOperation.prepare(listing);
    if (old != null &&
        old.outcome != QoderOutcome.unknown &&
        _sameCampaign(old.record, operation.intent)) {
      return QoderOutcome.alreadyClaimed;
    }
    final outcome = await operation.execute(
      identity: listing.identity,
      persistIntent: claim,
      exchange: exchange,
    );
    if (_known.contains(outcome)) await complete(operation.intent, outcome);
    return outcome;
  }

  Future<T> _locked<T>(
    Future<T> Function(RandomAccessFile, Map<String, QoderJournalEntry>) action,
  ) async {
    // Guard before any await so even separate objects in the owning isolate are safe.
    final path = root.absolute.path;
    if (!_busy.add(path)) throw const QoderFailure('JournalBusy');
    RandomAccessFile? handle;
    var locked = false;
    try {
      if (!Platform.isMacOS && !Platform.isLinux)
        throw const QoderFailure('PlatformNotValidated');
      if (await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.directory ||
          await root.resolveSymbolicLinks() != path ||
          (await root.stat()).mode & 0x3f != 0) {
        throw const QoderFailure('PrivateDirectoryRequired');
      }
      final file = File('$path${Platform.pathSeparator}qoder-intents.jsonl');
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        try {
          await file.create(exclusive: true);
        } on PathExistsException {
          /* Another process created the same owner. */
        }
      }
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file)
        throw const QoderFailure('JournalUnavailable');
      handle = await file.open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.exclusive);
        locked = true;
      } on FileSystemException {
        throw const QoderFailure('JournalBusy');
      }
      final length = await handle.length();
      if (length > _maxJournal) throw const QoderFailure('JournalFull');
      await handle.setPosition(0);
      final bytes = await handle.read(length);
      if (bytes.length != length) throw const QoderFailure('JournalCorrupt');
      final history = _history(utf8.decode(bytes, allowMalformed: false));
      return await action(handle, history);
    } catch (error) {
      if (error is QoderFailure) rethrow;
      throw const QoderFailure('JournalUnavailable');
    } finally {
      if (handle != null) {
        try {
          if (locked) await handle.unlock();
        } finally {
          await handle.close();
        }
      }
      _busy.remove(path);
    }
  }

  Future<void> _append(
    RandomAccessFile file,
    Map<String, Object?> event,
  ) async {
    final bytes = utf8.encode('${jsonEncode(event)}\n');
    final before = await file.length();
    if (before + bytes.length > _maxJournal)
      throw const QoderFailure('JournalFull');
    await file.setPosition(before);
    await file.writeFrom(bytes);
    await file.flush();
    if (await file.length() != before + bytes.length)
      throw const QoderFailure('JournalCorrupt');
    await file.setPosition(before);
    final readback = await file.read(bytes.length);
    if (readback.length != bytes.length ||
        List.generate(
          bytes.length,
          (i) => i,
        ).any((i) => readback[i] != bytes[i]))
      throw const QoderFailure('JournalCorrupt');
    await syncDirectory();
  }
}

Map<String, Object?> _record(Map input) {
  if (input.length != _recordKeys.length ||
      input.keys.any((key) => !_recordKeys.contains(key)))
    throw const QoderFailure('InvalidRecord');
  for (final key in [
    'providerId',
    'uid',
    'generation',
    'region',
    'campaignId',
    'campaignKey',
  ]) {
    if (input[key] is! String ||
        utf8.encode(input[key] as String).length > 4096)
      throw const QoderFailure('InvalidRecord');
  }
  final copy = Map<String, Object?>.from(input);
  try {
    QoderClaimOperation.resume(
      copy,
      QoderIdentity(
        copy['providerId'] as String,
        copy['uid'] as String,
        copy['generation'] as String,
        region: copy['region'] as String,
      ),
    );
  } catch (_) {
    throw const QoderFailure('InvalidRecord');
  }
  return Map.unmodifiable(copy);
}

String _subject(Map record) => jsonEncode([record['region'], record['uid']]);
bool _sameCampaign(Map a, Map b) => [
  'uid',
  'region',
  'campaignId',
  'campaignKey',
  'startAt',
  'endAt',
].every((key) => a[key] == b[key]);
bool _sameRecord(Map a, Map b) => _recordKeys.every((key) => a[key] == b[key]);

Map<String, QoderJournalEntry> _history(String text) {
  final result = <String, QoderJournalEntry>{};
  if (text.isEmpty) return result;
  if (!text.endsWith('\n')) throw const QoderFailure('JournalCorrupt');
  try {
    final lines = text.split('\n')..removeLast();
    for (final line in lines) {
      final event = decodeQoderObject(line);
      if (event == null || event['record'] is! Map)
        throw const QoderFailure('JournalCorrupt');
      final record = _record(event['record'] as Map);
      final subject = _subject(record);
      final old = result[subject];
      if (event['kind'] == 'intent' && event.length == 2) {
        if (old != null &&
            (old.outcome == QoderOutcome.unknown ||
                _sameCampaign(old.record, record) ||
                (record['startAt'] as int) < (old.record['endAt'] as int)))
          throw const QoderFailure('JournalCorrupt');
        result[subject] = QoderJournalEntry(record, QoderOutcome.unknown);
      } else if (event['kind'] == 'settled' && event.length == 3) {
        final outcomes = _known.where((v) => v.name == event['outcome']);
        if (outcomes.length != 1 ||
            old == null ||
            old.outcome != QoderOutcome.unknown ||
            !_sameRecord(old.record, record))
          throw const QoderFailure('JournalCorrupt');
        result[subject] = QoderJournalEntry(record, outcomes.single);
      } else {
        throw const QoderFailure('JournalCorrupt');
      }
    }
  } catch (_) {
    throw const QoderFailure('JournalCorrupt');
  }
  return result;
}
