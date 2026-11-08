import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'plugin_runtime.dart';

class PluginSignInFailure implements Exception {
  PluginSignInFailure(this.message);
  final String message;
  @override
  String toString() => 'PluginSignInFailure';
}

/// One native authorization conversation. No supplier protocol lives here.
class PluginSignIn {
  PluginSignIn(this.runtime, {required this.onSaved});
  final PluginRuntime runtime;
  final Future<void> Function(String) onSaved;
  final _cancellation = Completer<void>();
  String? _session;
  Future<String>? _finishing;

  Future<Map<String, dynamic>?> nextPrompt(
    String provider,
    int method,
    Map<String, String> inputs,
  ) async {
    final result = await runtime.call('prompt', {
      'provider': provider,
      'method': method,
      'inputs': inputs,
    }, cancellation: _cancellation.future) as Map;
    final prompt = result['prompt'];
    return prompt is Map ? Map<String, dynamic>.from(prompt) : null;
  }

  Future<String?> validate(
    String provider,
    int method,
    String key,
    String value,
  ) async {
    final result = await runtime.call('validate', {
      'provider': provider,
      'method': method,
      'key': key,
      'value': value,
    }, cancellation: _cancellation.future) as Map;
    return result['error'] as String?;
  }

  Future<Map<String, dynamic>> begin(
    String provider,
    int? method,
    Map<String, String> inputs, {
    String? account,
    Map<String, String>? context,
  }) async {
    if (_session != null || _cancellation.isCompleted)
      throw StateError('Sign-in already started or cancelled');
    final result = _success(
      await runtime.call('authorize', {
        'provider': provider,
        if (method != null) 'method': method,
        'inputs': inputs,
        'account': account ?? 'new',
        if (context != null) 'context': context,
      }, cancellation: _cancellation.future),
    );
    _session = result['session'] as String;
    return result;
  }

  Future<String> finish({String? code}) => _finishing ??= _finish(code);
  Future<String> _finish(String? code) async {
    if (_session == null || _cancellation.isCompleted)
      throw StateError('Sign-in unavailable');
    final result = _success(
      await runtime.call(
        'callback',
        {'session': _session, if (code != null) 'code': code},
        timeout: const Duration(minutes: 10),
        cancellation: _cancellation.future,
      ),
    );
    final account = result['account'] as String;
    await onSaved(account);
    return account;
  }

  Future<String> apiKey(
    String provider,
    int method,
    Map<String, String> inputs,
    String key,
  ) async {
    // Scope the opaque key without changing a provider's native prompt inputs.
    // This accountId is not an official UID and cannot authorize rewards.
    final scope = inputs.keys.toList()..sort();
    final identity = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              provider,
              method,
              {for (final name in scope) name: inputs[name]},
              key,
            ]),
          ),
        )
        .toString();
    final result = _success(
      await runtime.call('apiKey', {
        'provider': provider,
        'method': method,
        'inputs': inputs,
        'accountId': 'api:$identity',
        'key': key,
        'account': 'new',
      }, cancellation: _cancellation.future),
    );
    final account = result['account'] as String;
    await onSaved(account);
    return account;
  }

  void cancel() {
    if (!_cancellation.isCompleted) _cancellation.complete();
  }

  Map<String, dynamic> _success(Object? value) {
    if (value is! Map || value['ok'] != true) {
      throw PluginSignInFailure(
        value is Map && value['error'] is String ? value['error'] : '授权未完成。',
      );
    }
    return Map<String, dynamic>.from(value);
  }
}
