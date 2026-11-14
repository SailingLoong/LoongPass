import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'magpie_connection.dart';
import 'plugin_model_service.dart';

enum ModelConnectionFailure { notReady, saveFailed, changed }

/// Owns connection synchronization independently of page lifetime. Once the
/// user connects, startup and account/settings events keep native routing in
/// sync. Diagnostic observations remain explicit.
class ModelConnection extends ChangeNotifier {
  ModelConnection(this.models, this.bridgePath, {MagpieConnection? client})
    : _client = client ?? MagpieConnection() {
    _source = _sourceState;
    models.addListener(_changed);
  }

  final PluginModelService models;
  final String bridgePath;
  final MagpieConnection _client;
  MagpieInspection? inspection;
  DateTime? checkedAt;
  ModelConnectionFailure? error;
  bool busy = false;
  bool _closed = false;
  bool _started = false;
  int _revision = 0;
  late String _source;
  String? _registeredSource;
  String? _appliedRouting;
  Timer? _scheduled;

  List<PluginModelGrant> get _selected =>
      models.grants.where((g) => g.available).toList();
  int get selectedAccounts => _selected.length;
  int? get savedAccounts => inspection?.accountIds == null
      ? null
      : _selected
            .where((g) => inspection!.accountIds!.contains(g.account.key))
            .length;
  bool get canConnect => models.running && selectedAccounts > 0 && !busy;

  String get _sourceState => jsonEncode([
    models.enabled,
    models.running,
    models.endpoint?.toString(),
    for (final g in _selected)
      [g.account.key, g.account.registrationId, g.token],
  ]);
  String get _routingState => jsonEncode([
    _source,
    models.routingSettings,
    for (final g in models.grants)
      [g.account.key, g.account.models, g.account.usage, g.account.error],
  ]);

  void start() {
    _started = true;
    _schedule();
  }

  void _changed() {
    if (_closed) return;
    final source = _sourceState;
    if (source != _source) {
      _source = source;
      _revision++;
      inspection = null;
      checkedAt = null;
      error = null;
      notifyListeners();
    }
    _schedule();
  }

  void _schedule({bool retry = false}) {
    if (_closed ||
        !_started ||
        !models.routingConnected ||
        !models.running ||
        busy)
      return;
    if (!retry && _appliedRouting == _routingState) return;
    _scheduled?.cancel();
    _scheduled = Timer(
      retry ? const Duration(seconds: 30) : const Duration(milliseconds: 150),
      () => unawaited(_run(save: true, inspect: false)),
    );
  }

  Future<void> check() => _run(save: false, inspect: true);
  Future<void> connect() async {
    if (_closed || busy) return;
    if (!canConnect) {
      error = ModelConnectionFailure.notReady;
      notifyListeners();
      return;
    }
    _started = true;
    _registeredSource = null;
    await _run(save: true, inspect: true);
  }

  Future<void> _sync() async {
    final source = _source;
    if (_registeredSource != source && _selected.isNotEmpty) {
      await _client.connect(
        bridgePath,
        models.endpoint!,
        _selected,
        legacyKeys: models.legacyKeys,
        saveBackup: models.saveConnectionBackup,
      );
      if (_closed || source != _source) return;
      _registeredSource = source;
    }
    if (_closed) return;
    if (!models.routingConnected) await models.markRoutingConnected();
    final state = _routingState;
    final catalog = models.catalog;
    final groups = {
      for (final m in catalog)
        if (m.official &&
            m.enabled &&
            m.bindings.any(
              (b) => b.enabled && b.grant.enabled && b.account.active,
            ))
          m.groupId,
    };
    if (groups.isNotEmpty) groups.add('loongpass-auto');
    // Journal before native writes so a partially created group is reclaimed
    // on a retry or after a process restart.
    final previous = models.managedGroups;
    await models.saveManagedGroups({...previous, ...groups});
    if (_closed) return;
    await _client.syncRouting(bridgePath, catalog, previousGroups: previous);
    if (_closed) return;
    await models.saveManagedGroups(groups);
    _appliedRouting = state;
  }

  Future<void> _run({required bool save, required bool inspect}) async {
    if (_closed || busy) return;
    final revision = _revision;
    _scheduled?.cancel();
    busy = true;
    error = null;
    if (inspect) {
      inspection = null;
      checkedAt = null;
    }
    notifyListeners();
    var failed = false;
    try {
      if (save) await _sync();
      if (_closed) return;
      if (inspect) {
        final result = await _client.inspect();
        if (!_closed && revision == _revision) {
          inspection = result;
          checkedAt = DateTime.now();
        }
      }
    } catch (_) {
      failed = true;
      if (!_closed) error = ModelConnectionFailure.saveFailed;
    } finally {
      if (!_closed) {
        if (revision != _revision) error = ModelConnectionFailure.changed;
        busy = false;
        notifyListeners();
        _schedule(retry: failed);
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    _scheduled?.cancel();
    models.removeListener(_changed);
    super.dispose();
  }
}
