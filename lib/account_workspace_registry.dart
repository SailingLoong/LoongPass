import 'package:flutter/widgets.dart';
import 'account_table_entry.dart';
import 'managed_app.dart';

/// An ephemeral, read-only UI projection of platform-owned table snapshots.
/// It is never persisted or used by account/auth/claim code. Navigating consumers
/// cannot request refresh or change domain state through this registry.
class AccountWorkspaceRegistry extends ChangeNotifier {
  final _snapshots = <ManagedApp, List<AccountTableEntry>>{};
  final _sources = <ManagedApp, Object>{};
  bool _disposed = false;
  List<AccountTableEntry> entriesFor(ManagedApp app) =>
      _snapshots[app] ?? const [];
  List<({ManagedApp app, AccountTableEntry entry})> get accounts => [
    for (final app in ManagedApp.values)
      for (final entry in entriesFor(app))
        (
          app: app,
          entry: entry.inApp(app.name, '${app.label} · ${app.region}'),
        ),
  ];
  List<AccountTableEntry> get entries => accounts.map((a) => a.entry).toList();
  void publish(ManagedApp app, Object source, List<AccountTableEntry> entries) {
    if (_disposed) return;
    _sources[app] = source;
    _snapshots[app] = List.unmodifiable(entries);
    notifyListeners();
  }

  void remove(ManagedApp app, Object source) {
    if (_disposed || _sources[app] != source) return;
    _sources.remove(app);
    _snapshots.remove(app);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Scope for the owning platform's existing presentation. Only the platform
/// table publishes; aggregate tables have no source scope and cannot feed back.
class AccountPresentationScope extends InheritedWidget {
  const AccountPresentationScope({
    super.key,
    required this.app,
    required this.registry,
    required super.child,
  });
  final ManagedApp app;
  final AccountWorkspaceRegistry registry;
  static AccountPresentationScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AccountPresentationScope>();
  @override
  bool updateShouldNotify(AccountPresentationScope oldWidget) =>
      app != oldWidget.app || registry != oldWidget.registry;
}
