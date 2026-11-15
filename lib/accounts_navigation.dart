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
    required this.onSelectApp,
    required this.onHideApp,
    this.enabledApps,
  });

  final UiPreferences preferences;
  final bool compact, active;
  final ManagedApp? selectedApp;
  final Set<ManagedApp>? enabledApps;
  final VoidCallback onOpen;
  final ValueChanged<ManagedApp> onSelectApp, onHideApp;

  @override
  Widget build(BuildContext context) {
    final apps = preferences.appOrder
        .where((app) => enabledApps == null || enabledApps!.contains(app))
        .toList();
    final visible = apps.where(preferences.isAppVisible).toList();
    final hidden = apps.where((app) => !preferences.isAppVisible(app)).toList();
    final navigation = SidebarNavigationButton(
      key: const Key('nav-accounts'),
      label: '账号与积分',
      icon: const Icon(FLucideIcons.wallet, size: 18),
      compact: compact,
      selected: active && selectedApp == null,
      onPressed: onOpen,
    );
    final disclosure = Semantics(
      expanded: preferences.appsExpanded,
      child: SizedBox.square(
        dimension: 32,
        child: FButton.icon(
          key: const Key('toggle-account-apps'),
          variant: FButtonVariant.ghost,
          size: FButtonSizeVariant.sm,
          semanticsLabel: preferences.appsExpanded ? '收起应用列表' : '展开应用列表',
          onPress: () => preferences.setAppsExpanded(!preferences.appsExpanded),
          child: Icon(
            preferences.appsExpanded
                ? FLucideIcons.chevronDown
                : FLucideIcons.chevronRight,
            size: 16,
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        compact
            ? Column(children: [navigation, disclosure])
            : Row(
                children: [
                  Expanded(child: navigation),
                  const SizedBox(width: 4),
                  disclosure,
                ],
              ),
        Expanded(
          child: preferences.appsExpanded
              ? Column(
                  key: const Key('account-apps'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: CustomScrollView(
                        key: const PageStorageKey('account-app-scroll'),
                        primary: false,
                        slivers: [
                          SliverReorderableList(
                            key: const Key('visible-app-order'),
                            itemCount: visible.length,
                            onReorderItem: (from, to) => preferences.reorder(
                              preferences.appOrder.indexOf(visible[from]),
                              preferences.appOrder.indexOf(visible[to]),
                            ),
                            proxyDecorator: (child, index, animation) =>
                                MouseRegion(
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
                                      preferences.appOrder.indexOf(
                                        visible[target],
                                      ),
                                    );
                                  }
                                },
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    if (hidden.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: FPopoverMenu(
                          menuAnchor: Alignment.bottomLeft,
                          childAnchor: Alignment.bottomRight,
                          menuBuilder: (context, controller, _) => [
                            FItemGroup(
                              children: [
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
                )
              : const SizedBox.shrink(),
        ),
        const FDivider(
          style: FDividerStyleDelta.delta(
            padding: EdgeInsetsGeometryDelta.value(
              EdgeInsets.symmetric(vertical: 8),
            ),
          ),
        ),
      ],
    );
  }
}
