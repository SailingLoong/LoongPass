import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'magpie_connection.dart';
import 'plugin_model_service.dart';

enum ModelConnectionFailure { notReady, saveFailed, changed }

/// Owns explicit connection operations and their observations, independent of
/// page lifetime. Account/service events invalidate evidence; they never probe.
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
  int _revision = 0;
  late String _source;

  List<PluginModelGrant> get _selected =>
      models.grants.where((g) => g.enabled && g.account.active).toList();
  int get selectedAccounts => _selected.length;
  int? get savedAccounts => inspection?.accountIds == null
      ? null
      : _selected
            .where((g) => inspection!.accountIds!.contains(g.account.key))
            .length;
  bool get canConnect => models.running && selectedAccounts > 0 && !busy;

  String get _sourceState => jsonEncode([
    models.enabled, models.running, models.endpoint?.toString(),
    // A replacement credential can keep the same account ID.
    for (final g in _selected)
      [g.account.key, g.account.registrationId, g.token],
  ]);

  void _changed() {
    final source = _sourceState;
    if (_closed || source == _source) return;
    _source = source;
    _revision++;
    inspection = null;
    checkedAt = null;
    error = null;
    notifyListeners();
  }

  Future<void> check() => _run(false);
  Future<void> connect() => _run(true);

  Future<void> _run(bool save) async {
    if (_closed || busy) return;
    if (save && !canConnect) {
      error = ModelConnectionFailure.notReady;
      notifyListeners();
      return;
    }
    final revision = _revision;
    busy = true;
    error = null;
    inspection = null;
    checkedAt = null;
    notifyListeners();
    try {
      if (save) {
        await _client.connect(
          bridgePath,
          models.endpoint!,
          _selected,
          legacyKeys: models.legacyKeys,
          saveBackup: models.saveConnectionBackup,
        );
      }
      if (_closed) return;
      final result = await _client.inspect();
      if (!_closed && revision == _revision) {
        inspection = result;
        checkedAt = DateTime.now();
      }
    } catch (_) {
      if (!_closed) error = ModelConnectionFailure.saveFailed;
    } finally {
      if (!_closed) {
        if (revision != _revision) error = ModelConnectionFailure.changed;
        busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    models.removeListener(_changed);
    super.dispose();
  }
}
