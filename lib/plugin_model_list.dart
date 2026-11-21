import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'plugin_model_catalog.dart';

class PluginModelList extends StatelessWidget {
  const PluginModelList({
    super.key,
    required this.models,
    required this.busy,
    required this.onSelect,
    required this.onPublish,
    required this.candidates,
  });
  final List<PluginModel> models;
  final bool busy;
  final ValueChanged<String> onSelect;
  final void Function(String, bool) onPublish;
  final List<PluginModel>? candidates;

  @override
  Widget build(BuildContext context) {
    final muted = context.theme.typography.body.xs.copyWith(
      color: context.theme.colors.mutedForeground,
    );
    final order = candidates;
    return ListView.builder(
      shrinkWrap: true,
      primary: false,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: models.length,
      itemBuilder: (context, index) {
        final model = models[index];
        return Container(
          key: ValueKey('model-${model.id}'),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: context.theme.colors.border),
            ),
          ),
          child: Row(
            children: [
              if (order != null)
                Text(
                  (order.indexOf(model) + 1).toString().padLeft(2, '0'),
                  style: muted,
                ),
              Expanded(
                child: FButton(
                  key: ValueKey('open-model-${model.id}'),
                  variant: FButtonVariant.ghost,
                  size: FButtonSizeVariant.sm,
                  mainAxisAlignment: MainAxisAlignment.start,
                  onPress: () => onSelect(model.id),
                  child: Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          model.name,
                          style: context.theme.typography.body.md.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text('${model.availableAccounts} 个可用账号', style: muted),
                      ],
                    ),
                  ),
                ),
              ),
              if (order == null)
                FSwitch(
                  key: ValueKey('model-published-${model.id}'),
                  semanticsLabel: '在 Magpie 中显示并参与 Auto ${model.name}',
                  value: model.published,
                  enabled: !busy,
                  onChange: (value) => onPublish(model.id, value),
                ),
            ],
          ),
        );
      },
    );
  }
}
