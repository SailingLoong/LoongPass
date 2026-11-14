import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'app_navigation_item.dart';
import 'managed_app.dart';
import 'ui_preferences.dart';

class AccountsNavigation extends StatelessWidget {
  const AccountsNavigation({
    super.key,
    required this.preferences,
    required this.compact,
    required this.active,
    required this.selectedApp,
    required this.onOpen,
    required this.onSelectAll,
    required this.onSelectApp,
    required this.onHideApp,
    this.enabledApps,
  });

  final UiPreferences preferences;
  final bool compact, active;
  final ManagedApp? selectedApp;
  final Set<ManagedApp>? enabledApps;
  final VoidCallback onOpen, onSelectAll;
  final ValueChanged<ManagedApp> onSelectApp, onHideApp;

  @override
  Widget build(BuildContext context) {
    final apps = preferences.appOrder
        .where((app) => enabledApps == null || enabledApps!.contains(app))
        .toList();
    final visible = apps.where(preferences.isAppVisible).toList();
    final hidden = apps.where((app) => !preferences.isAppVisible(app)).toList();
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Semantics(
            expanded: preferences.appsExpanded,
            child: SidebarNavigationButton(
              key: const Key('nav-accounts'),
              label: '账号与积分',
              icon: const Icon(FLucideIcons.wallet, size: 18),
              compact: compact,
              selected: active,
              trailing: Icon(
                preferences.appsExpanded
                    ? FLucideIcons.chevronDown
                    : FLucideIcons.chevronRight,
                size: 14,
              ),
              onPressed: () {
                if (active) {
                  preferences.setAppsExpanded(!preferences.appsExpanded);
                } else {
                  onOpen();
                }
              },
            ),
          ),
        ),
        if (preferences.appsExpanded)
          SliverPadding(
            key: const Key('account-apps'),
            padding: EdgeInsets.only(left: compact ? 0 : 12, top: 4, bottom: 8),
            sliver: SliverMainAxisGroup(
              slivers: [
                SliverToBoxAdapter(
                  child: SidebarNavigationButton(
                    key: const Key('app-all'),
                    label: '全部',
                    icon: const Icon(FLucideIcons.layoutGrid, size: 18),
                    compact: compact,
                    selected: active && selectedApp == null,
                    onPressed: onSelectAll,
                  ),
                ),
                SliverReorderableList(
                  key: const Key('visible-app-order'),
                  itemCount: visible.length,
                  onReorderItem: (from, to) => preferences.reorder(
                    preferences.appOrder.indexOf(visible[from]),
                    preferences.appOrder.indexOf(visible[to]),
                  ),
                  proxyDecorator: (child, index, animation) => MouseRegion(
                    cursor: SystemMouseCursors.grabbing,
                    child: IgnorePointer(
                      child: ColoredBox(
                        color: context.theme.colors.muted,
                        child: child,
                      ),
                    ),
                  ),
                  itemBuilder: (context, index) {
                    final app = visible[index];
                    return AppNavigationItem(
                      key: ValueKey('visible-${app.name}'),
                      app: app,
                      index: index,
                      compact: compact,
                      selected: active && selectedApp == app,
                      onPressed: () => onSelectApp(app),
                      onHide: () => onHideApp(app),
                      onMove: (delta) {
                        final target = index + delta;
                        if (target >= 0 && target < visible.length) {
                          preferences.reorder(
                            preferences.appOrder.indexOf(app),
                            preferences.appOrder.indexOf(visible[target]),
                          );
                        }
                      },
                    );
                  },
                ),
                SliverToBoxAdapter(
                  child: FPopoverMenu(
                    menuAnchor: Alignment.topLeft,
                    childAnchor: Alignment.bottomLeft,
                    menuBuilder: (context, controller, _) => [
                      FItemGroup(
                        children: [
                          if (hidden.isEmpty)
                            FItem(title: const Text('全部应用已展示'), enabled: false),
                          for (final app in hidden)
                            FItem(
                              key: ValueKey('show-${app.name}'),
                              prefix: ManagedAppIcon(app: app),
                              title: Text(app.label),
                              subtitle: Text(app.region),
                              onPress: () {
                                preferences.setAppVisible(app, true);
                                controller.hide();
                              },
                            ),
                        ],
                      ),
                    ],
                    builder: (context, controller, _) =>
                        SidebarNavigationButton(
                          key: const Key('show-apps'),
                          label: '展示应用',
                          icon: const Icon(FLucideIcons.plus, size: 18),
                          compact: compact,
                          selected: false,
                          onPressed: controller.toggle,
                        ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
