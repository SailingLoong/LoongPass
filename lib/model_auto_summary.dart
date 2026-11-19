import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'desktop_theme.dart';

class ModelAutoSummary extends StatelessWidget {
  const ModelAutoSummary({
    super.key,
    required this.count,
    required this.running,
    this.onOpen,
  });
  final int count;
  final bool running;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final info = Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: context.desktopPalette.selected,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            FLucideIcons.workflow,
            color: context.desktopPalette.selectedForeground,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'LoongPass Auto',
                style: context.theme.typography.body.lg.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '$count 个候选模型 · 新会话优先使用较早到期的额度',
                style: context.theme.typography.body.xs,
              ),
            ],
          ),
        ),
      ],
    );
    final action = onOpen == null
        ? Text(running ? '本机服务运行中' : '本机服务已关闭')
        : FButton(
            variant: FButtonVariant.outline,
            size: FButtonSizeVariant.sm,
            mainAxisSize: MainAxisSize.min,
            onPress: onOpen,
            prefix: const Icon(FLucideIcons.arrowRight, size: 14),
            child: const Text('候选顺序'),
          );
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.desktopPalette.sidebar,
        borderRadius: BorderRadius.circular(10),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          if (box.maxWidth < 400 * scale) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [info, const SizedBox(height: 12), action],
            );
          }
          return Row(
            children: [
              Expanded(child: info),
              const SizedBox(width: 12),
              action,
            ],
          );
        },
      ),
    );
  }
}
