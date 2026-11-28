import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'magpie_connection.dart';
import 'magpie_model_routing.dart';
import 'plugin_model_catalog.dart';
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
  bool _restorePending = true;
  int _revision = 0;
  late String _source;
  String? _registeredSource;
  String? _appliedRouting;
  Timer? _scheduled;
  Timer? _quotaBoundary;
  Timer? _orderTimer;
  bool _checkingOrder = false;
  List<String>? _publicOrder;

  List<PluginModelGrant> get _selected =>
      models.grants.where((g) => g.available).toList();
  int get selectedAccounts => _selected.length;
  int? get savedAccounts => inspection?.accountIds == null
      ? null
      : _selected
            .where((g) => inspection!.accountIds!.contains(g.account.key))
            .length;
  bool get canConnect =>
      models.running && models.catalogReady && selectedAccounts > 0 && !busy;

  bool get canStartAndConnect =>
      !models.running && models.catalogReady && selectedAccounts > 0 && !busy;

  Future<void> startAndConnect() async {
    if (_closed || !canStartAndConnect) return;
    busy = true;
    notifyListeners();
    try {
      await models.setEnabled(true);
    } catch (_) {
      error = ModelConnectionFailure.saveFailed;
      return;
    } finally {
      busy = false;
      if (!_closed) notifyListeners();
    }
    await connect();
  }

  String get _sourceState => jsonEncode([
    models.enabled,
    models.running,
    models.catalogReady,
    models.endpoint?.toString(),
    for (final g in _selected)
      [g.account.key, g.account.registrationId, g.token],
  ]);
  AutoRoutingPriority get autoPriority =>
      AutoRoutingPriority.fromSettings(models.routingSettings);
  MagpieModelRouting get routing => _routingForDisplay(models.catalog);

  MagpieModelRouting _routingForDisplay(List<PluginModel> catalog) {
    final result = _routingFor(catalog);
    final order = _publicOrder;
    if (models.running && order != null) {
      result.usePublicOrder(order);
    }
    return result;
  }

  Map<String, String> get accountModelStatus {
    final ready = models.catalogReady;
    final catalog = ready ? models.catalog : const <PluginModel>[];
    final available = ready
        ? _routingForDisplay(catalog).availableAccounts
        : const <String>{};
    String? reason(PluginModelGrant grant) {
      final account = grant.account;
      if (grant.authorizationRequired) return '需要重新登录';
      if (!grant.enabled) return '未开放模型权限';
      if (!ready ||
          !account.catalogObserved ||
          account.error == 'catalog_unavailable') {
        return account.error == 'catalog_unavailable' || models.catalogFailed
            ? '模型读取失败'
            : '正在读取模型';
      }
      if (available.contains(account.key)) return null;
      final matched = catalog.where(
        (m) =>
            m.official && m.bindings.any((b) => b.account.key == account.key),
      );
      if (matched.isEmpty) return '尚未发现适用模型';
      final published = matched.where((m) => m.published);
      if (published.isEmpty) return '模型尚未启用';
      final bindings = published
          .expand((m) => m.bindings)
          .where((b) => b.account.key == account.key && b.enabled);
      if (bindings.isEmpty) return '未参与当前模型';
      if (bindings.every(
        (b) =>
            b.status == ModelQuotaStatus.exhausted ||
            b.status == ModelQuotaStatus.expired,
      ))
        return '适用额度已用完或到期';
      return '暂无可用路由';
    }

    return {
      for (final g in models.grants)
        if (reason(g) case final status?) g.account.key: status,
    };
  }

  MagpieModelRouting _routingFor(List<PluginModel> catalog) =>
      MagpieModelRouting(catalog, priority: autoPriority);

  String _routingState(MagpieModelRouting routing) => jsonEncode([
    _source,
    models.routingSettings,
    for (final g in models.grants)
      [g.account.key, g.account.models, g.account.usage, g.account.error],
    for (final group in routing.groups.entries)
      [group.key, group.value.name, group.value.members],
  ]);

  void start() {
    if (_closed || _started) return;
    _started = true;
    _orderTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(_checkOrder()),
    );
    _schedule();
  }

  Future<void> _checkOrder() async {
    final previous = _publicOrder;
    if (_closed ||
        busy ||
        _checkingOrder ||
        previous == null ||
        !models.running ||
        !models.routingConnected)
      return;
    final ids = _routingFor(models.catalog).publicIds;
    if (ids.isEmpty) return;
    _checkingOrder = true;
    try {
      final order = await _client.publicOrder(ids);
      if (_closed ||
          busy ||
          !identical(previous, _publicOrder) ||
          listEquals(previous, order))
        return;
      _appliedRouting = null;
      _schedule();
    } catch (_) {
      // A transient failure keeps the last confirmed catalog until the next check.
    } finally {
      _checkingOrder = false;
    }
  }

  void _changed() {
    if (_closed) return;
    final source = _sourceState;
    if (source != _source) {
      _publicOrder = null;
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
    _quotaBoundary?.cancel();
    _quotaBoundary = null;
    if (_closed || !_started || !models.running || !models.catalogReady) return;
    final catalog = models.catalog;
    // Quota facts can change with time even when an upstream snapshot remains
    // identical. Schedule that boundary here, independently of view/request reads.
    final boundaries =
        catalog
            .expand((m) => m.bindings)
            .map((b) => b.quota.nextChangeAt)
            .whereType<DateTime>()
            .toList()
          ..sort();
    if (boundaries.isNotEmpty) {
      _quotaBoundary = Timer(boundaries.first.difference(DateTime.now()), () {
        _schedule();
        notifyListeners();
      });
    }
    if (busy ||
        (!models.routingConnected && (!_restorePending || _selected.isEmpty))) {
      return;
    }
    if (!retry && _appliedRouting == _routingState(_routingFor(catalog))) {
      return;
    }
    _scheduled?.cancel();
    _scheduled = Timer(
      retry ? const Duration(seconds: 30) : const Duration(milliseconds: 150),
      () => unawaited(
        _run(save: true, inspect: false, restore: !models.routingConnected),
      ),
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
    start();
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
    if (_closed || source != _source) return;
    final snapshot = _routingFor(models.catalog);
    final state = _routingState(snapshot);
    final groups = snapshot.groups.keys.toSet();
    // Journal before native writes so a partially created group is reclaimed
    // on a retry or after a process restart.
    final previous = models.managedGroups;
    await models.saveManagedGroups({...previous, ...groups});
    if (_closed || source != _source) return;
    final order = await _client.syncRouting(
      bridgePath,
      snapshot,
      previousGroups: previous,
    );
    if (_closed || source != _source) return;
    _publicOrder = order;
    await models.rememberPublishedOrder([
      for (final model in snapshot.candidates) model.id,
    ]);
    if (_closed) return;
    await models.saveManagedGroups(snapshot.groups.keys.toSet());
    _appliedRouting = state;
  }

  Future<void> _run({
    required bool save,
    required bool inspect,
    bool restore = false,
  }) async {
    if (_closed || busy || (save && !models.catalogReady)) return;
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
      if (restore) {
        final saved = await _client.hasSavedConnection(bridgePath, _selected);
        if (_closed || revision != _revision) return;
        if (!saved) {
          _restorePending = false;
          return;
        }
        // Preserve existing connection intent before native writes, so retries
        // and restarts finish upgrading a partially synchronized connection.
        await models.markRoutingConnected();
        _restorePending = false;
        if (_closed || revision != _revision) return;
      }
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
    _orderTimer?.cancel();
    _quotaBoundary?.cancel();
    models.removeListener(_changed);
    super.dispose();
  }
}
