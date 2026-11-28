import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'operation_log.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'managed_app.dart';

enum _ExpandedNavigation { accounts, models }

/// Owns UI choices only. Account owners remain authoritative for all account
/// facts; no credentials, balances or claim records are written here.
class UiPreferences extends ChangeNotifier {
  UiPreferences({this.read, this.write});
  factory UiPreferences.persistent() {
    final store = SharedPreferencesAsync();
    const key = 'loongpass.workspace.v1';
    return UiPreferences(
      read: () => store.getString(key),
      write: (value) => store.setString(key, value),
    );
  }
  final Future<String?> Function()? read;
  final Future<void> Function(String)? write;
  List<ManagedApp> _order = [...ManagedApp.values];
  final Set<ManagedApp> _hiddenApps = {};
  _ExpandedNavigation? _expandedNavigation = _ExpandedNavigation.accounts;
  final Set<String> _favorites = {};
  final Map<String, int> _pageSizes = {};
  bool _comfortable = false, _disposed = false;
  ThemeMode _themeMode = ThemeMode.system;
  int _revision = 0;
  Future<void> _pending = Future.value();
  String? error;
  List<ManagedApp> get appOrder => List.unmodifiable(_order);
  bool get appsExpanded => _expandedNavigation == _ExpandedNavigation.accounts;
  bool get modelsExpanded => _expandedNavigation == _ExpandedNavigation.models;
  bool isAppVisible(ManagedApp app) => !_hiddenApps.contains(app);
  bool get comfortable => _comfortable;
  double get rowHeight => _comfortable ? 44 : 36;
  ThemeMode get themeMode => _themeMode;
  Future<void> get saved => _pending;
  bool isFavorite(String id) => _favorites.contains(id);
  int pageSize(String scope) => _pageSizes[scope] ?? 10;

  Future<void> load() async {
    final revision = _revision;
    try {
      final raw = await read?.call();
      if (_disposed || revision != _revision || raw == null) return;
      final json = jsonDecode(raw);
      if (json is! Map) throw const FormatException();
      final order = json['appOrder'];
      if (order is List) {
        _order = {
          for (final id in order)
            for (final app in ManagedApp.values)
              if (app.name == id) app,
          ...ManagedApp.values,
        }.toList();
      }
      final hidden = json['hiddenApps'];
      _hiddenApps
        ..clear()
        ..addAll(
          ManagedApp.values.where(
            (app) => hidden is List && hidden.contains(app.name),
          ),
        );
      _expandedNavigation = null;
      if (json['modelsExpanded'] == true) {
        _expandedNavigation = _ExpandedNavigation.models;
      } else if (json['appsExpanded'] != false) {
        _expandedNavigation = _ExpandedNavigation.accounts;
      }
      _comfortable = json['comfortable'] == true;
      _themeMode =
          ThemeMode.values.where((v) => v.name == json['theme']).firstOrNull ??
          ThemeMode.system;
      final favorites = json['favorites'];
      if (favorites is List) _favorites.addAll(favorites.whereType<String>());
      final sizes = json['pageSizes'];
      if (sizes is Map) {
        for (final entry in sizes.entries) {
          if (entry.key is String && const [5, 10, 20].contains(entry.value)) {
            _pageSizes[entry.key] = entry.value;
          }
        }
      }
      error = null;
    } catch (_) {
      if (!_disposed) error = '界面偏好未能读取，暂时使用默认布局。';
    }
    if (!_disposed) notifyListeners();
  }

  void reorder(int from, int to) {
    if (from == to ||
        from < 0 ||
        to < 0 ||
        from >= _order.length ||
        to >= _order.length)
      return;
    _order.insert(to, _order.removeAt(from));
    _changed('appOrder');
  }

  void resetOrder() {
    _order = [...ManagedApp.values];
    _changed('resetOrder');
  }

  void setAppVisible(ManagedApp app, bool visible) {
    final changed = visible ? _hiddenApps.remove(app) : _hiddenApps.add(app);
    if (changed) _changed('appVisibility');
  }

  void setAppsExpanded(bool value) =>
      _setExpandedNavigation(_ExpandedNavigation.accounts, value);

  void setModelsExpanded(bool value) =>
      _setExpandedNavigation(_ExpandedNavigation.models, value);

  void _setExpandedNavigation(_ExpandedNavigation group, bool value) {
    if (!value && _expandedNavigation != group) return;
    final expanded = value ? group : null;
    if (_expandedNavigation == expanded) return;
    _expandedNavigation = expanded;
    _changed('navigation');
  }

  void setComfortable(bool value) {
    _comfortable = value;
    _changed('density');
  }

  void setTheme(ThemeMode value) {
    _themeMode = value;
    _changed('theme');
  }

  void toggleFavorite(String id) {
    _favorites.contains(id) ? _favorites.remove(id) : _favorites.add(id);
    _changed('favorite');
  }

  void setPageSize(String scope, int size) {
    if (!const [5, 10, 20].contains(size)) return;
    _pageSizes[scope] = size;
    _changed('pageSize');
  }

  void retrySave() => _changed('retrySave');

  void _changed(String setting) {
    final revision = ++_revision;
    notifyListeners();
    if (write == null) return;
    final payload = jsonEncode({
      'appOrder': _order.map((a) => a.name).toList(),
      'hiddenApps': _hiddenApps.map((app) => app.name).toList(),
      'appsExpanded': appsExpanded,
      'modelsExpanded': modelsExpanded,
      'comfortable': _comfortable,
      'theme': _themeMode.name,
      'favorites': _favorites.toList(),
      'pageSizes': _pageSizes,
    });
    // A single serialized writer prevents a slow earlier change from replacing
    // a later drag/favorite choice. Errors are visible, never claimed as saved.
    _pending = _pending.then((_) async {
      try {
        await OperationLog.trace('preference', setting, () => write!(payload));
        if (!_disposed && revision == _revision) error = null;
      } catch (_) {
        if (!_disposed) error = '界面偏好尚未保存；本次调整仍保留在当前窗口。';
      }
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class UiPreferencesScope extends InheritedNotifier<UiPreferences> {
  const UiPreferencesScope({
    super.key,
    required UiPreferences preferences,
    required super.child,
  }) : super(notifier: preferences);
  static UiPreferences? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<UiPreferencesScope>()
      ?.notifier;
}
