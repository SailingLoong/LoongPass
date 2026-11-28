import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'desktop_theme.dart';

class WorkspacePage extends StatelessWidget {
  const WorkspacePage({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.controller,
    required this.children,
  });
  final String title;
  final String? subtitle;
  final Widget? action;
  final List<Widget> children;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final horizontal = math.max(
        context.desktopGutter,
        (box.maxWidth - 1220) / 2,
      );
      return DefaultTextStyle(
        style: context.theme.typography.body.sm,
        child: ListView(
          controller: controller,
          padding: EdgeInsets.fromLTRB(horizontal, 26, horizontal, 40),
          children: [
            WorkspaceHeading(title: title, subtitle: subtitle, action: action),
            const SizedBox(height: 26),
            ...children,
          ],
        ),
      );
    },
  );
}

class WorkspaceHeading extends StatelessWidget {
  const WorkspaceHeading({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
  });
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: context.desktopPageTitle),
        ),
        if (subtitle != null && subtitle!.isNotEmpty) ...[
          const SizedBox(height: 7),
          Text(
            subtitle!,
            style: context.theme.typography.body.sm.copyWith(
              color: context.theme.colors.mutedForeground,
              height: 1.5,
            ),
          ),
        ],
      ],
    );
    final control = action;
    if (control == null) return identity;
    return LayoutBuilder(
      builder: (context, box) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        if (box.maxWidth < 390 * scale) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [identity, const SizedBox(height: 10), control],
          );
        }
        return Row(
          children: [
            Expanded(flex: 3, child: identity),
            const SizedBox(width: 12),
            Flexible(
              flex: 2,
              child: Align(alignment: Alignment.centerRight, child: control),
            ),
          ],
        );
      },
    );
  }
}

class WorkspaceCard extends StatelessWidget {
  const WorkspaceCard({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: FCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: child,
      ),
    ),
  );
}
