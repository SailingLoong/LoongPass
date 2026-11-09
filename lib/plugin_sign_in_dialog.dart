import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart' show SelectableText;
import 'package:flutter/services.dart';

import 'plugin_accounts.dart';
import 'plugin_sign_in.dart';

class PluginSignInDialog extends StatefulWidget {
  const PluginSignInDialog({
    super.key,
    this.animation,
    required this.accounts,
    required this.providerIds,
    required this.title,
    this.initialProvider,
    this.target,
    this.authorizationContext = const {},
  });
  final Animation<double>? animation;
  final PluginAccounts accounts;
  final Set<String> providerIds;
  final String title;
  final String? initialProvider;
  final PluginAccount? target;
  final Map<String, String> authorizationContext;
  @override
  State<PluginSignInDialog> createState() => _PluginSignInDialogState();
}

enum _Step { select, prompt, key, code, waiting, failed }

class _PluginSignInDialogState extends State<PluginSignInDialog> {
  static const _channel = MethodChannel('com.sailingloong.loongpass/files');
  late PluginSignIn _signIn;
  final _input = TextEditingController();
  final _inputs = <String, String>{};
  String? _provider, _selected, _error, _browserError;
  int? _method;
  Map<String, dynamic>? _prompt, _authorization;
  _Step _step = _Step.select;
  bool _busy = false, _ended = false;
  late final PluginAccount? _target;
  late final Map<String, String> _targetContext;

  List<Map> get _methods => [
    for (final m
        in widget.accounts.providers[_provider]?['methods'] as List? ??
            const [])
      m is Map ? m : const <String, dynamic>{},
  ];
  Map get _chosen => _method != null && _method! < _methods.length
      ? _methods[_method!]
      : const <String, dynamic>{};

  @override
  void initState() {
    super.initState();
    final target = widget.target;
    _target =
        target != null &&
            target.uid.isNotEmpty &&
            widget.accounts.providers[target.provider]?['reauthorize'] == true
        ? target
        : null;
    _targetContext = Map.unmodifiable({
      ...widget.authorizationContext,
      if (_target != null) ...{
        'expectedUid': _target.uid,
        'expectedRealm': _target.realm,
      },
    });
    _signIn = PluginSignIn(widget.accounts.runtime, onSaved: _saved);
    final available = widget.providerIds.where(
      widget.accounts.providers.containsKey,
    );
    _provider = available.contains(widget.initialProvider)
        ? widget.initialProvider
        : available.firstOrNull;
    _selectMethod();
  }

  Future<void> _saved(String key) => widget.accounts.authorizationSaved(
    key,
    expectedRegistrationId: _target?.registrationId,
  );

  void _selectMethod() {
    _method = null;
    for (var i = 0; i < _methods.length; i++) {
      if ({'oauth', 'api'}.contains(_methods[i]['type'])) {
        _method = i;
        break;
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || _ended) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted && !_ended)
        setState(() {
          _step = _Step.failed;
          _error = '授权未完成。请核对官方页面的结果后重新开始。';
        });
    } finally {
      if (mounted && !_ended) setState(() => _busy = false);
    }
  }

  Future<void> _next() async {
    if (_target != null) return _begin();
    final prompt = await _signIn.nextPrompt(_provider!, _method!, _inputs);
    if (!mounted || _ended) return;
    if (prompt != null) {
      if (!{'select', 'text', 'password'}.contains(prompt['type']) ||
          prompt['key'] is! String)
        throw StateError('Unsupported native prompt');
      setState(() {
        _prompt = prompt;
        _step = _Step.prompt;
        _selected = null;
        _input.clear();
      });
      return;
    }
    if (_chosen['type'] == 'api') {
      if (_chosen['keyless'] == true) {
        _complete(await _signIn.apiKey(_provider!, _method!, _inputs, ''));
      } else {
        setState(() {
          _step = _Step.key;
          _input.clear();
        });
      }
      return;
    }
    await _begin();
  }

  Future<void> _begin() async {
    if (_target != null &&
        !widget.accounts.accounts.any(
          (a) =>
              a.key == _target.key &&
              a.registrationId == _target.registrationId &&
              a.uid == _target.uid &&
              a.realm == _target.realm,
        )) {
      throw StateError('Authorization target changed');
    }
    final auth = await _signIn.begin(
      _target?.provider ?? _provider!,
      _target == null ? _method! : null,
      _inputs,
      account: _target?.key,
      context: _target == null ? null : _targetContext,
    );
    if (!mounted || _ended) return;
    if (!{'auto', 'code'}.contains(auth['method'])) {
      throw StateError('Unsupported authorization callback');
    }
    setState(() {
      _authorization = auth;
      _step = auth['method'] == 'auto' ? _Step.waiting : _Step.code;
      _input.clear();
    });
    if (auth['url'] is String &&
        (auth['url'] as String).isNotEmpty &&
        auth['opened'] != true)
      await _open();
    if (mounted && !_ended && _step == _Step.waiting) unawaited(_finish());
  }

  Future<void> _continue() => _run(() async {
    if (_step == _Step.select) return _next();
    if (_step == _Step.prompt) {
      final value = _prompt!['type'] == 'select' ? _selected : _input.text;
      if (value == null) {
        setState(() => _error = '请选择一项。');
        return;
      }
      final error = await _signIn.validate(
        _provider!,
        _method!,
        _prompt!['key'],
        value,
      );
      if (!mounted || _ended) return;
      if (error != null) {
        setState(() => _error = error);
        return;
      }
      _inputs[_prompt!['key']] = value;
      return _next();
    }
    if (_step == _Step.key) {
      if (_input.text.trim().isEmpty) {
        setState(() => _error = '请填写 API key。');
        return;
      }
      _complete(
        await _signIn.apiKey(_provider!, _method!, _inputs, _input.text.trim()),
      );
    } else if (_step == _Step.code) {
      if (_input.text.trim().isEmpty) {
        setState(() => _error = '请填写官方返回的验证码。');
        return;
      }
      _complete(await _signIn.finish(code: _input.text.trim()));
    }
  });

  Future<void> _finish() async {
    try {
      _complete(await _signIn.finish());
    } catch (_) {
      if (mounted && !_ended)
        setState(() {
          _step = _Step.failed;
          _error = '官方授权尚未完成或等待已结束，请重新开始。';
        });
    }
  }

  void _complete(String key) {
    if (mounted && !_ended) {
      _ended = true;
      Navigator.of(context).pop(key);
    }
  }

  void _cancel() {
    _ended = true;
    _signIn.cancel();
    Navigator.of(context).pop();
  }

  Future<void> _open() async {
    try {
      final uri = Uri.tryParse(_authorization?['url'] as String? ?? '');
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException();
      }
      await _channel.invokeMethod<void>('openExternalHTTPS', {
        'url': uri.toString(),
      });
      if (mounted) setState(() => _browserError = null);
    } catch (_) {
      if (mounted) setState(() => _browserError = '未能打开浏览器。可复制授权链接手动打开，或再次尝试。');
    }
  }

  Future<void> _copyLink() async {
    try {
      await Clipboard.setData(ClipboardData(text: _authorization!['url']));
    } catch (_) {
      if (mounted && !_ended)
        setState(() => _browserError = '未能复制授权链接，请再次尝试打开授权页面。');
    }
  }

  void _restart() {
    _signIn.cancel();
    _signIn = PluginSignIn(widget.accounts.runtime, onSaved: _saved);
    setState(() {
      _inputs.clear();
      _input.clear();
      _prompt = null;
      _authorization = null;
      _error = null;
      _browserError = null;
      _step = _Step.select;
    });
  }

  @override
  void dispose() {
    _signIn.cancel();
    _input.dispose();
    super.dispose();
  }

  Widget _entry(String label, {bool secret = false, String? placeholder}) =>
      FTextField(
        key: const Key('plugin-auth-input'),
        control: FTextFieldControl.managed(controller: _input),
        label: Text(label),
        hint: placeholder,
        enabled: !_busy,
        obscureText: secret,
        autocorrect: false,
        enableSuggestions: !secret,
        onSubmit: (_) => unawaited(_continue()),
      );

  @override
  Widget build(BuildContext context) => PopScope<String>(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) {
        _ended = true;
        _signIn.cancel();
      }
    },
    child: FDialog(
      animation: widget.animation,
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 640),
      builder: (context, style) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DefaultTextStyle(
              style: style.titleTextStyle,
              child: Text(widget.title),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: DefaultTextStyle(
                style: style.bodyTextStyle,
                child: SizedBox(
                  width: 480,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_step == _Step.select && _target != null)
                          Text(
                            '将通过官方授权更新 ${_target.label}（${_target.realm} · ${_target.uid}）。',
                          ),
                        if (_step == _Step.select && _target == null) ...[
                          FSelect<String>.rich(
                            key: const Key('plugin-auth-provider'),
                            label: const Text('平台'),
                            enabled: !_busy,
                            format: (id) =>
                                widget.accounts.providers[id]?['name']
                                    as String? ??
                                id,
                            children: [
                              for (final id in widget.providerIds)
                                if (widget.accounts.providers.containsKey(id))
                                  FSelectItem(
                                    value: id,
                                    title: Text(
                                      widget.accounts.providers[id]?['name']
                                              as String? ??
                                          id,
                                    ),
                                  ),
                            ],
                            control: FSelectControl.lifted(
                              value: _provider,
                              onChange: (value) => setState(() {
                                _provider = value;
                                _selectMethod();
                              }),
                            ),
                          ),
                          const SizedBox(height: 12),
                          FSelect<int>.rich(
                            key: const ValueKey('plugin-auth-method'),
                            label: const Text('授权方式'),
                            enabled: !_busy,
                            format: (index) =>
                                _methods[index]['label'] as String? ??
                                '授权方式 ${index + 1}',
                            children: [
                              for (
                                var index = 0;
                                index < _methods.length;
                                index++
                              )
                                if ({
                                  'oauth',
                                  'api',
                                }.contains(_methods[index]['type']))
                                  FSelectItem(
                                    value: index,
                                    title: Text(
                                      _methods[index]['label'] as String? ??
                                          '授权方式 ${index + 1}',
                                    ),
                                  ),
                            ],
                            control: FSelectControl.lifted(
                              value: _method,
                              onChange: (value) =>
                                  setState(() => _method = value),
                            ),
                          ),
                          if (_method == null)
                            const Padding(
                              padding: EdgeInsets.only(top: 12),
                              child: Text('平台授权方式暂不可用，请关闭后刷新账号列表。'),
                            ),
                        ],
                        if (_step == _Step.prompt)
                          if (_prompt!['type'] == 'select')
                            FSelect<String>.rich(
                              key: const Key('plugin-auth-prompt-select'),
                              label: Text(
                                _prompt!['message'] as String? ?? '请选择',
                              ),
                              enabled: !_busy,
                              format: (value) {
                                final options =
                                    _prompt!['options'] as List? ?? const [];
                                final option = options
                                    .whereType<Map>()
                                    .where((option) => option['value'] == value)
                                    .firstOrNull;
                                return option?['label'] as String? ?? value;
                              },
                              children: [
                                for (final option
                                    in _prompt!['options'] as List? ?? const [])
                                  if (option is Map &&
                                      option['value'] is String)
                                    FSelectItem(
                                      value: option['value'] as String,
                                      title: Text(
                                        option['label'] as String? ??
                                            option['value'] as String,
                                      ),
                                    ),
                              ],
                              control: FSelectControl.lifted(
                                value: _selected,
                                onChange: (value) =>
                                    setState(() => _selected = value),
                              ),
                            )
                          else
                            _entry(
                              _prompt!['message'] as String? ?? '请填写',
                              secret: _prompt!['type'] == 'password',
                              placeholder: _prompt!['placeholder'] as String?,
                            ),
                        if (_step == _Step.key)
                          _entry(
                            _chosen['label'] as String? ?? 'API key',
                            secret: true,
                            placeholder: _chosen['placeholder'] as String?,
                          ),
                        if (_authorization != null) ...[
                          if ((_authorization!['instructions'] as String? ?? '')
                              .isNotEmpty)
                            SelectableText(_authorization!['instructions']),
                          if ((_authorization!['url'] as String? ?? '')
                              .isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              children: [
                                FButton(
                                  variant: FButtonVariant.ghost,
                                  size: FButtonSizeVariant.sm,
                                  mainAxisSize: MainAxisSize.min,
                                  child: const Text('打开授权页面'),
                                  onPress: _open,
                                ),
                                FButton(
                                  variant: FButtonVariant.ghost,
                                  size: FButtonSizeVariant.sm,
                                  mainAxisSize: MainAxisSize.min,
                                  child: const Text('复制授权链接'),
                                  onPress: _copyLink,
                                ),
                              ],
                            ),
                          ],
                        ],
                        if (_browserError != null)
                          Text(
                            _browserError!,
                            style: TextStyle(color: context.theme.colors.error),
                          ),
                        if (_step == _Step.code) ...[
                          const SizedBox(height: 12),
                          _entry('官方验证码', secret: true),
                        ],
                        if (_step == _Step.waiting)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Text('请在官方页面完成授权，正在等待结果。'),
                          ),
                        if (_busy || _step == _Step.waiting) const FProgress(),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: context.theme.colors.error,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                FButton(
                  variant: FButtonVariant.ghost,
                  size: FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  child: const Text('取消'),
                  onPress: _cancel,
                ),
                if (_step == _Step.failed)
                  FButton(
                    variant: FButtonVariant.primary,
                    size: FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    child: const Text('重新开始'),
                    onPress: _busy ? null : _restart,
                  )
                else if (_step != _Step.waiting)
                  FButton(
                    variant: FButtonVariant.primary,
                    size: FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    child: Text(
                      _step == _Step.code || _step == _Step.key ? '完成授权' : '继续',
                    ),
                    onPress: _busy || _target == null && _method == null
                        ? null
                        : _continue,
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
