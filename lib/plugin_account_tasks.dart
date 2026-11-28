import 'dart:async';

import 'operation_log.dart';

typedef _AccountJob = ({
  String account,
  String provider,
  int limit,
  Future<void> Function() start,
});

/// Shared by account maintenance, catalog reads and user-initiated reward work.
/// Jobs waiting on another account of the same provider leave room for others.
class PluginAccountTasks {
  static const _limit = 3;
  static const _providerLimit = 2;
  final _active = <String, String>{};
  final _pending = <_AccountJob>[];

  Future<void> run(
    String account,
    int declaredLimit,
    Future<void> Function() action,
  ) {
    final provider = account.split('#').first;
    final done = Completer<void>();
    _pending.add((
      account: account,
      provider: provider,
      limit: declaredLimit > 0
          ? declaredLimit.clamp(1, _providerLimit)
          : _providerLimit,
      start: () async {
        try {
          await OperationLog.trace('task', 'account', action);
          done.complete();
        } catch (error, stack) {
          done.completeError(error, stack);
        } finally {
          _active.remove(account);
          _drain();
        }
      },
    ));
    _drain();
    return done.future;
  }

  void _drain() {
    while (_active.length < _limit) {
      final index = _pending.indexWhere(
        (job) =>
            !_active.containsKey(job.account) &&
            _active.values.where((p) => p == job.provider).length < job.limit,
      );
      if (index < 0) return;
      final job = _pending.removeAt(index);
      _active[job.account] = job.provider;
      unawaited(job.start());
    }
  }
}
