import 'package:flutter/foundation.dart';

import 'plugin_model_catalog.dart';
import 'plugin_model_service.dart';

class ModelWorkspaceViewModel extends ChangeNotifier {
  ModelWorkspaceViewModel(this.service);
  final PluginModelService service;
  bool busy = false;
  bool showAll = false;
  String query = '';
  String? error;
  bool _disposed = false;

  void search(String text) {
    query = text.trim().toLowerCase();
    notifyListeners();
  }

  void setShowAll(bool value) {
    showAll = value;
    notifyListeners();
  }

  ({
    PluginModel? selected,
    List<PluginModel> candidates,
    List<PluginModel> visible,
    bool noSources,
  })
  snapshot(String? selectedId) {
    final catalog = service.catalog;
    final official = catalog.where((model) => model.official);
    final candidates = official.where((model) => model.enabled).toList();
    final displayed = selectedId == 'auto'
        ? candidates
        : official.where(
            (model) => showAll || model.published || query.isNotEmpty,
          );
    return (
      selected: official.where((model) => model.id == selectedId).firstOrNull,
      candidates: candidates,
      visible: displayed
          .where((model) => model.searchText.contains(query))
          .toList(),
      noSources: catalog.isEmpty && service.grants.isEmpty,
    );
  }

  Future<void> _save(Future<void> Function() action) async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
    } catch (_) {
      error = '设置保存失败，请重试。';
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> publish(String id, bool value) =>
      _save(() => service.setModelPublished(id, value));
  Future<void> participate(String id, bool value) =>
      _save(() => service.setModelEnabled(id, value));
  Future<void> authorize(String key, bool value) =>
      _save(() => service.enable(key, value));
  Future<void> enableSource(String id, String key, bool value) =>
      _save(() => service.setModelAccountEnabled(id, key, value));
  Future<void> enableService(bool value) =>
      _save(() => service.setEnabled(value));
  Future<void> retain(List<PluginModel> visible) => _save(() async {
    await service.retainModels(visible.map((m) => m.id).toSet());
    showAll = false;
  });
  Future<void> move(String from, String to) => _save(() async {
    final order = service.catalog.map((m) => m.id).toList();
    final source = order.indexOf(from), target = order.indexOf(to);
    if (source < 0 || target < 0 || source == target) return;
    order.insert(target, order.removeAt(source));
    await service.reorderModels(order);
  });

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
