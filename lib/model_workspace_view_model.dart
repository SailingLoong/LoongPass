import 'package:flutter/foundation.dart';

import 'plugin_model_catalog.dart';
import 'plugin_model_service.dart';

class ModelWorkspaceViewModel extends ChangeNotifier {
  ModelWorkspaceViewModel(this.service);
  final PluginModelService service;
  bool busy = false;
  bool showAll = false;
  String query = '';
  ({String message, String? accountKey})? error;
  bool _disposed = false;

  void search(String text) {
    query = text.trim().toLowerCase();
    notifyListeners();
  }

  void setShowAll(bool value) {
    showAll = value;
    notifyListeners();
  }

  ({PluginModel? selected, List<PluginModel> visible, bool noSources}) snapshot(
    String? selectedId, {
    List<PluginModel>? candidates,
    String? queryOverride,
  }) {
    final query = queryOverride ?? this.query;
    final catalog = candidates ?? service.catalog;
    final official = catalog.where((model) => model.official);
    bool matches(PluginModel model) => model.searchText.contains(query);
    final displayed =
        candidates ??
        official.where(
          (model) => showAll || model.published || query.isNotEmpty,
        );
    return (
      selected: catalog.where((model) => model.id == selectedId).firstOrNull,
      visible: displayed.where(matches).toList(),
      noSources: catalog.isEmpty && service.grants.isEmpty,
    );
  }

  Future<void> _save(
    Future<void> Function() action, {
    String? accountKey,
  }) async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
    } catch (_) {
      error = (message: '设置保存失败，请重试。', accountKey: accountKey);
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> publish(String id, bool value) =>
      _save(() => service.setModelPublished(id, value));
  Future<void> selectPriority(AutoRoutingPriority priority) =>
      _save(() => service.setAutoRoutingPriority(priority));
  Future<void> authorize(String key, bool value) =>
      _save(() => service.enable(key, value), accountKey: key);
  Future<void> enableSource(String id, String key, bool value) => _save(
    () => service.setModelAccountEnabled(id, key, value),
    accountKey: key,
  );
  Future<void> enableService(bool value) =>
      _save(() => service.setEnabled(value));
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
