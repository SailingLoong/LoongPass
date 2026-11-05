import 'package:flutter/material.dart';

enum ManagedApp {
  zcode('ZCode', 'Z', Color(0xFF1664FF)),
  qoderCn('Qoder CN', 'Q', Color(0xFF7554D9)),
  qoder('Qoder', 'Q', Color(0xFF7554D9)),
  minimaxCn('MiniMax CN', 'M', Color(0xFFE66B32)),
  minimax('MiniMax', 'M', Color(0xFFE66B32)),
  workbuddy('WorkBuddy', 'W', Color(0xFF168978)),
  traeCn('TRAE CN', 'T', Color(0xFF168978));

  const ManagedApp(this.label, this.monogram, this.color);
  final String label;
  final String monogram;
  final Color color;
}

/// Navigation only: selecting an app never switches an account or runs I/O.
/// Pages stay mounted, retaining unfinished input and in-flight operation state.
class AppWorkspace extends StatefulWidget {
  const AppWorkspace({
    super.key,
    required this.pages,
    this.initialApp = ManagedApp.zcode,
    this.enabledApps,
  });
  final Map<ManagedApp, Widget> pages;
  final ManagedApp initialApp;
  final Set<ManagedApp>? enabledApps;

  @override
  State<AppWorkspace> createState() => _AppWorkspaceState();
}

class _AppWorkspaceState extends State<AppWorkspace> {
  late ManagedApp _selected;
  @override
  void initState() {
    super.initState();
    _selected = widget.initialApp;
  }

  bool _collapsed = false;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 760 || _collapsed;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: const Color(0xFFF2F4F7),
            child: SizedBox(
              key: const Key('app-sidebar'),
              width: compact ? 76 : 188,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: compact
                        ? const Tooltip(
                            message: 'LoongPass',
                            child: Icon(Icons.switch_account_outlined),
                          )
                        : const Text(
                            'LoongPass',
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                  if (constraints.maxWidth >= 760)
                    IconButton(
                      key: const Key('toggle-sidebar'),
                      tooltip: compact ? '展开应用栏' : '收起应用栏',
                      onPressed: () => setState(() => _collapsed = !_collapsed),
                      icon: Icon(
                        compact ? Icons.chevron_right : Icons.chevron_left,
                      ),
                    ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      children: [
                        for (final app in ManagedApp.values)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Semantics(
                              key: ValueKey('selected-${app.name}'),
                              selected: _selected == app,
                              child: Tooltip(
                                message: app.label,
                                child: TextButton(
                                  key: ValueKey('app-${app.name}'),
                                  onPressed:
                                      widget.enabledApps == null ||
                                          widget.enabledApps!.contains(app)
                                      ? () => setState(() => _selected = app)
                                      : null,
                                  style: TextButton.styleFrom(
                                    minimumSize: const Size(44, 48),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                    foregroundColor: _selected == app
                                        ? const Color(0xFF1664FF)
                                        : const Color(0xFF4E5969),
                                    backgroundColor: _selected == app
                                        ? const Color(0xFFE1EAFF)
                                        : Colors.transparent,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: compact
                                        ? MainAxisAlignment.center
                                        : MainAxisAlignment.start,
                                    children: [
                                      ExcludeSemantics(
                                        child: Container(
                                          width: 28,
                                          height: 28,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            color: app.color,
                                            borderRadius: BorderRadius.circular(
                                              7,
                                            ),
                                          ),
                                          child: Text(
                                            app.monogram,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ),
                                      if (!compact) ...[
                                        const SizedBox(width: 10),
                                        Flexible(
                                          child: Text(
                                            app.label,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                      if (compact)
                                        Semantics(
                                          label: app.label,
                                          child: const SizedBox.shrink(),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '开发预览',
                      style: TextStyle(fontSize: 11, color: Color(0xFF86909C)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const VerticalDivider(
            width: 1,
            thickness: 1,
            color: Color(0xFFE5E6EB),
          ),
          Expanded(
            child: IndexedStack(
              index: _selected.index,
              sizing: StackFit.expand,
              children: [
                for (final app in ManagedApp.values)
                  KeyedSubtree(
                    key: ValueKey('page-${app.name}'),
                    child:
                        widget.pages[app] ??
                        Center(child: Text('${app.label} 尚未接入')),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );
}
