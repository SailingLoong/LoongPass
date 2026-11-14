import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'invitation_settings.dart';

class InvitationSettingsPanel extends StatefulWidget {
  const InvitationSettingsPanel({super.key, required this.settings});
  final InvitationSettings settings;

  @override
  State<InvitationSettingsPanel> createState() =>
      _InvitationSettingsPanelState();
}

class _InvitationSettingsPanelState extends State<InvitationSettingsPanel> {
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
    final theme = context.theme;
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: FTextField(
              key: Key('${widget.settings.app.name}-invitation-code'),
              control: FTextFieldControl.managed(
                controller: _input,
                onChange: (_) => setState(() => _message = _error = null),
              ),
              label: const Text('邀请码'),
              size: FTextFieldSizeVariant.sm,
              hint: widget.settings.defaultCode,
              description: const Text('留空使用默认邀请码。添加账号时可前往官方邀请页注册。'),
              error: _error == null ? null : Text(_error!),
              enabled: !_saving && widget.settings.ready,
              autocorrect: false,
            ),
          ),
          const SizedBox(height: 10),
          if (widget.settings.error != null) ...[
            Text(widget.settings.error!),
            FButton(
              variant: FButtonVariant.outline,
              size: FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              onPress: _reload,
              child: const Text('重试读取'),
            ),
          ] else
            FButton(
              key: Key('${widget.settings.app.name}-invitation-save'),
              variant: FButtonVariant.outline,
              size: FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              onPress:
                  _saving || _input.text.trim() == widget.settings.overrideCode
                  ? null
                  : _save,
              child: Text(_saving ? '正在保存…' : '保存邀请码'),
            ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_message!, style: theme.typography.body.sm),
            ),
        ],
      ),
    );
  }
}
