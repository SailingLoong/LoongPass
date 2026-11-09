import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'workbuddy_invitation.dart';

class WorkBuddyInvitationPanel extends StatefulWidget {
  const WorkBuddyInvitationPanel({super.key, required this.settings});
  final WorkBuddyInvitation settings;

  @override
  State<WorkBuddyInvitationPanel> createState() =>
      _WorkBuddyInvitationPanelState();
}

class _WorkBuddyInvitationPanelState extends State<WorkBuddyInvitationPanel> {
  late final _input = TextEditingController(text: widget.settings.overrideCode);
  bool _saving = false;
  String? _message, _error;

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _message = _error = null;
    });
    try {
      await widget.settings.save(_input.text);
      if (mounted) {
        _input.text = widget.settings.overrideCode;
        setState(() => _message = '邀请码已保存');
      }
    } on FormatException {
      if (mounted) setState(() => _error = '请填写邀请码，可使用字母、数字、横线或下划线。');
    } catch (_) {
      if (mounted) setState(() => _error = '邀请码尚未保存，请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reload() async {
    await widget.settings.load();
    if (mounted && widget.settings.ready) {
      _input.text = widget.settings.overrideCode;
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).brightness == Brightness.dark
        ? FTheme.neutral.dark.desktop
        : FTheme.neutral.light.desktop;
    return FTheme(
      data: theme,
      child: ListenableBuilder(
        listenable: widget.settings,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('邀请设置', style: theme.typography.display.lg),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: FTextField(
                key: const Key('workbuddy-invitation-code'),
                control: FTextFieldControl.managed(
                  controller: _input,
                  onChange: (_) => setState(() => _message = _error = null),
                ),
                label: const Text('邀请码'),
                hint: WorkBuddyInvitation.defaultCode,
                description: const Text('留空使用默认邀请码。新用户可在添加账号时前往官方邀请注册页。'),
                error: _error == null ? null : Text(_error!),
                enabled: !_saving && widget.settings.ready,
                autocorrect: false,
              ),
            ),
            const SizedBox(height: 12),
            if (widget.settings.error != null) ...[
              Text(widget.settings.error!),
              FButton(onPress: _reload, child: const Text('重试读取')),
            ] else
              IntrinsicWidth(
                child: FButton(
                  key: const Key('workbuddy-invitation-save'),
                  onPress: _saving ? null : _save,
                  child: Text(_saving ? '正在保存…' : '保存邀请码'),
                ),
              ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_message!, style: theme.typography.body.sm),
              ),
          ],
        ),
      ),
    );
  }
}
