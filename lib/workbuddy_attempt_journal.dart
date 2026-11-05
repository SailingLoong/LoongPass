// Noncredential receipt persistence using the existing Qoder journal approach.
// No tokens, credential store, database, background service, or reset operation.
import 'dart:convert';
import 'dart:io';
import 'qoder_claim.dart' show decodeQoderObject;
import 'workbuddy_claim.dart';

const _maxJournal = 16 * 1024 * 1024;
const _maxRow = 8192;
const _fields = {
  'revision', 'domain', 'uid', 'generation', 'day', 'before',
  'receipt', 'expected', 'settled', 'credited',
};

/// Single owning isolate only. The guard serializes this isolate; POSIX locks
/// serialize cooperating processes, not other isolates in the same process.
/// The existing native owner prepares a private root and fsyncs its hierarchy.
/// Missing/empty files are first setup, as for Qoder. Any malformed/partial
/// existing log fails closed and is never trimmed, replaced, or reset.
///
/// This protects ordinary exceptions and process restart, not malicious
/// same-UID edits, manual deletion, old-backup rollback, or bypassing this owner.
/// Identifiers are local plaintext; credentials must never be passed as fields.
class WorkBuddyAttemptJournal implements WorkBuddyAttemptStore {
  static final _busy = <String>{};
  final Directory root;
  final Future<void> Function() syncDirectory;
  final bool Function(WorkBuddySubject) isCurrent;
  WorkBuddyAttemptJournal(this.root, {
    required this.syncDirectory,
    required this.isCurrent,
  });

  @override
  Future<WorkBuddyAttempt?> read(String subjectKey) {
    _validateKey(subjectKey);
    return _locked((_, history) async => history[subjectKey]);
  }

  @override
  Future<bool> compareAndSet(String subjectKey, int? expectedRevision,
    WorkBuddyAttempt next) {
    _validateKey(subjectKey);
    _validate(next);
    if (next.subject.key != subjectKey ||
        next.revision != (expectedRevision ?? -1) + 1) _invalid();
    return _locked((file, history) async {
      final previous = history[subjectKey];
      if (previous?.revision != expectedRevision) return false;
      _transition(previous, next);
      return _append(file, next);
    });
  }

  Future<T> _locked<T>(Future<T> Function(RandomAccessFile,
      Map<String, WorkBuddyAttempt>) action) async {
    // Register before awaiting, including across separate owner objects.
    final path = root.absolute.path;
    if (!_busy.add(path)) throw const WorkBuddyFailure('JournalBusy');
    RandomAccessFile? handle;
    var locked = false;
    try {
      if (!Platform.isMacOS && !Platform.isLinux)
        throw const WorkBuddyFailure('PlatformNotValidated');
      if (await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.directory ||
          await root.resolveSymbolicLinks() != path ||
          (await root.stat()).mode & 0x3f != 0) {
        throw const WorkBuddyFailure('PrivateDirectoryRequired');
      }
      final file = File('$path${Platform.pathSeparator}workbuddy-intents.jsonl');
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        try {
          await file.create(exclusive: true);
        } on PathExistsException {
          // A cooperating process may have created the same file first.
        }
      }
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file)
        throw const WorkBuddyFailure('JournalUnavailable');
      handle = await file.open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.exclusive);
        locked = true;
      } on FileSystemException {
        throw const WorkBuddyFailure('JournalBusy');
      }
      final length = await handle.length();
      if (length > _maxJournal) throw const WorkBuddyFailure('JournalFull');
      await handle.setPosition(0);
      final bytes = await handle.read(length);
      if (bytes.length != length) throw const WorkBuddyFailure('JournalCorrupt');
      final Map<String, WorkBuddyAttempt> history;
      try {
        history = _history(utf8.decode(bytes, allowMalformed: false));
      } catch (_) {
        throw const WorkBuddyFailure('JournalCorrupt');
      }
      return await action(handle, history);
    } catch (error) {
      if (error is WorkBuddyFailure) rethrow;
      throw const WorkBuddyFailure('JournalUnavailable');
    } finally {
      try {
        if (handle != null) {
          try {
            if (locked) await handle.unlock();
          } finally { await handle.close(); }
        }
      } finally { _busy.remove(path); }
    }
  }

  Future<bool> _append(RandomAccessFile file, WorkBuddyAttempt next) async {
    final bytes = utf8.encode('${jsonEncode(_encode(next))}\n');
    final before = await file.length();
    if (before + bytes.length > _maxJournal)
      throw const WorkBuddyFailure('JournalFull');
    await file.setPosition(before);
    // Last synchronous lifecycle check before initiating the append.
    if (!isCurrent(next.subject)) return false;
    try {
      await file.writeFrom(bytes);
      await file.flush();
      if (await file.length() != before + bytes.length)
        throw const WorkBuddyFailure('JournalCorrupt');
      await file.setPosition(before);
      final readback = await file.read(bytes.length);
      if (readback.length != bytes.length)
        throw const WorkBuddyFailure('JournalCorrupt');
      for (var i = 0; i < bytes.length; i++) {
        if (bytes[i] != readback[i])
          throw const WorkBuddyFailure('JournalCorrupt');
      }
      await syncDirectory();
      // A revoked or failed acknowledgment never permits POST. The possibly
      // committed row remains intact, including across another owner's restart.
      return isCurrent(next.subject);
    } catch (_) {
      throw const WorkBuddyFailure('StorageCommitUncertain');
    }
  }
}

Never _invalid() => throw const WorkBuddyFailure('InvalidAttemptRecord');
bool _terminal(WorkBuddyState state) =>
  state != WorkBuddyState.unconfirmed && state != WorkBuddyState.available;

void _validateKey(String key) {
  try {
    final value = jsonDecode(key);
    if (value is! List || value.length != 2 || value[0] is! String ||
        value[1] is! String ||
        WorkBuddySubject(value[0], value[1], 'validate').key != key) _invalid();
  } catch (_) { _invalid(); }
}

void _validate(WorkBuddyAttempt r) {
  // Reconstruct to validate even subclasses or records supplied by other code.
  WorkBuddySubject(r.subject.domain, r.subject.uid, r.subject.generation);
  if (r.revision < 0 || r.revision > 9007199254740991 ||
      r.subject.generation.trim().isEmpty ||
      r.subject.generation.length > 256 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(r.subject.generation) ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(r.day) ||
      DateTime.tryParse(r.day)?.toIso8601String().substring(0, 10) != r.day ||
      !r.before.isFinite || r.before < 0 ||
      (r.expected != null && (!r.expected!.isFinite || r.expected! < 0)) ||
      (r.credited != null && (!r.credited!.isFinite || r.credited! <= 0)) ||
      r.receipt == WorkBuddyState.available || r.settled == WorkBuddyState.available ||
      (r.settled != WorkBuddyState.unconfirmed && r.settled != r.receipt) ||
      (r.settled == WorkBuddyState.claimed &&
        (r.expected == null || r.expected! <= 0 || r.credited != r.expected)) ||
      (r.settled != WorkBuddyState.claimed && r.credited != null)) _invalid();
}

void _transition(WorkBuddyAttempt? previous, WorkBuddyAttempt next) {
  if (next.revision != (previous?.revision ?? -1) + 1) _invalid();
  if (previous == null || _terminal(previous.settled)) {
    if (next.receipt != WorkBuddyState.unconfirmed ||
        next.settled != WorkBuddyState.unconfirmed ||
        next.expected != null || next.credited != null ||
        (previous != null && next.day.compareTo(previous.day) <= 0)) _invalid();
    return;
  }
  // Unresolved generations/days/baselines cannot be replaced. Once a receipt
  // or expected amount exists it cannot be erased or rewritten.
  if (!previous.subject.matches(next.subject) || previous.day != next.day ||
      previous.before != next.before ||
      ((previous.receipt != WorkBuddyState.unconfirmed || previous.expected != null) &&
        (next.receipt != previous.receipt || next.expected != previous.expected)) ||
      (next.settled != WorkBuddyState.unconfirmed &&
        (previous.receipt == WorkBuddyState.unconfirmed ||
          next.receipt != previous.receipt || next.expected != previous.expected))) _invalid();
}

Map<String, Object?> _encode(WorkBuddyAttempt r) => {
  'revision': r.revision, 'domain': r.subject.domain, 'uid': r.subject.uid,
  'generation': r.subject.generation, 'day': r.day, 'before': r.before,
  'receipt': r.receipt.name, 'expected': r.expected,
  'settled': r.settled.name, 'credited': r.credited,
};

WorkBuddyAttempt _decode(String line) {
  if (utf8.encode(line).length > _maxRow) _invalid();
  // Reuse the existing decoder, including rejection of duplicate/escaped keys.
  final d = decodeQoderObject(line);
  if (d == null || d.length != _fields.length ||
      d.keys.any((key) => !_fields.contains(key)) ||
      d['revision'] is! int || d['domain'] is! String || d['uid'] is! String ||
      d['generation'] is! String || d['day'] is! String || d['before'] is! num ||
      d['receipt'] is! String || d['settled'] is! String ||
      (d['expected'] != null && d['expected'] is! num) ||
      (d['credited'] != null && d['credited'] is! num)) _invalid();
  final row = WorkBuddyAttempt(revision: d['revision'],
    subject: WorkBuddySubject(d['domain'], d['uid'], d['generation']),
    day: d['day'], before: (d['before'] as num).toDouble(),
    receipt: WorkBuddyState.values.byName(d['receipt']),
    expected: (d['expected'] as num?)?.toDouble(),
    settled: WorkBuddyState.values.byName(d['settled']),
    credited: (d['credited'] as num?)?.toDouble());
  _validate(row);
  return row;
}

Map<String, WorkBuddyAttempt> _history(String text) {
  final rows = <String, WorkBuddyAttempt>{};
  if (text.isEmpty) return rows;
  if (!text.endsWith('\n')) _invalid();
  final lines = text.split('\n')..removeLast();
  for (final line in lines) {
    final row = _decode(line);
    _transition(rows[row.subject.key], row);
    rows[row.subject.key] = row;
  }
  return rows;
}
