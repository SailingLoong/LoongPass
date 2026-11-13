import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'plugin_environment.dart';
import 'plugin_stream.dart';
export 'plugin_stream.dart'
    show PluginFetch, PluginResponse, PluginRuntimeFailure;

/// Transport for the pinned, unmodified Magpie plugin host.
class PluginRuntime {
  PluginRuntime._(this._process) {
    _process.stdout.listen(_read, onError: (_) => _lost(), onDone: _lost);
    // Plugin diagnostics can contain credentials. Drain without publishing them.
    _process.stderr.listen((_) {}, onError: (_) {});
    unawaited(_process.exitCode.then((_) => _lost()));
  }

  final Process _process;
  final _calls = <int, Completer<Object?>>{};
  final _fetches = <int, PluginStream>{};
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _line = BytesBuilder(copy: false);
  int _nextId = 0;
  bool _closing = false;
  bool _dead = false;
  Future<void>? _closeFuture;
  List<String> _providers = const [];
  List<String> get providerIds => _providers;
  static const _maxLine = 32 << 20;

  Stream<Map<String, dynamic>> get events => _events.stream;

  PluginFetch fetch(Map<String, Object?> params) {
    if (_closing || _dead) throw const PluginRuntimeFailure('host_closed');
    if (_fetches.length >= 128) throw const PluginRuntimeFailure('host_busy');
    final id = ++_nextId;
    final stream = PluginStream(
      credit: (n) => _notify('credit', {'id': id, 'n': n}),
      abort: () => _notify('abort', {'id': id}),
      release: () => _fetches.remove(id),
    );
    _fetches[id] = stream;
    try {
      _send({
        'id': id,
        'method': 'fetch',
        'params': {...params, 'window': 512 << 10},
      });
    } catch (_) {
      stream.fail(const PluginRuntimeFailure('request_not_sent'));
    }
    return stream;
  }

  void _notify(String method, Map<String, Object?> params) {
    if (!_dead) _send({'method': method, 'params': params});
  }

  static Future<PluginRuntime> start({
    required String executable,
    required String hostPath,
    required String launcherPath,
    required String directory,
    required List<Map<String, Object?>> plugins,
  }) async {
    await Directory(directory).create(recursive: true);
    if (!Platform.isWindows) {
      final permissions = await Process.run('chmod', ['700', directory]);
      if (permissions.exitCode != 0) {
        throw const PluginRuntimeFailure('private_directory_unavailable');
      }
    }
    final process = await Process.start(
      executable,
      [launcherPath, hostPath],
      workingDirectory: directory,
      environment: {
        ...await pluginHostEnvironment(Platform.environment),
        'DO_NOT_TRACK': '1',
        'NO_COLOR': '1',
      },
      includeParentEnvironment: false,
    );
    final runtime = PluginRuntime._(process);
    try {
      final result = await runtime.call('init', {
        'authPath': '$directory/plugin-auth.json',
        'directory': directory,
        'plugins': plugins,
      });
      if (result is! Map ||
          result['plugins'] is! List ||
          (result['plugins'] as List).length != plugins.length ||
          (result['plugins'] as List).any(
            (p) => p is! Map || p['error'] != null,
          )) {
        throw const PluginRuntimeFailure('plugin_load_failed');
      }
      runtime._providers = List.unmodifiable([
        for (final plugin in result['plugins'] as List)
          for (final provider in plugin['provides'] as List? ?? const [])
            if (provider is String) provider,
      ]);
      return runtime;
    } catch (_) {
      await runtime.close();
      rethrow;
    }
  }

  Future<Object?> call(
    String method,
    Map<String, Object?> params, {
    Duration timeout = const Duration(seconds: 30),
    Future<void>? cancellation,
  }) async {
    if (_closing || _dead) throw const PluginRuntimeFailure('host_closed');
    if (_calls.length >= 64) throw const PluginRuntimeFailure('host_busy');
    final id = ++_nextId;
    final result = Completer<Object?>();
    _calls[id] = result;
    void cancel() {
      if (_calls.remove(id) == null) return;
      _notify('abort', {'id': id});
      result.completeError(const PluginRuntimeFailure('request_cancelled'));
    }

    if (cancellation != null)
      unawaited(cancellation.then((_) => cancel(), onError: (_) => cancel()));
    final timer = Timer(timeout, () {
      if (_calls.remove(id) == null) return;
      _send({
        'method': 'abort',
        'params': {'id': id},
      });
      result.completeError(const PluginRuntimeFailure('request_timeout'));
    });
    try {
      _send({'id': id, 'method': method, 'params': params});
      return await result.future;
    } finally {
      timer.cancel();
      _calls.remove(id);
    }
  }

  void _send(Map<String, Object?> message) {
    if (_dead) throw const PluginRuntimeFailure('host_closed');
    final bytes = utf8.encode('${jsonEncode(message)}\n');
    if (bytes.length > _maxLine) {
      throw const PluginRuntimeFailure('request_too_large');
    }
    _process.stdin.add(bytes);
  }

  void _read(List<int> bytes) {
    try {
      var start = 0;
      for (var i = 0; i < bytes.length; i++) {
        if (bytes[i] != 10) continue;
        _append(bytes.sublist(start, i));
        if (_line.length > 0) {
          final value = jsonDecode(utf8.decode(_line.takeBytes()));
          if (value is! Map<String, dynamic>) throw const FormatException();
          _receive(value);
        }
        start = i + 1;
      }
      _append(bytes.sublist(start));
    } catch (_) {
      _lost();
      _process.kill();
    }
  }

  void _append(List<int> bytes) {
    if (_line.length + bytes.length > _maxLine) throw const FormatException();
    _line.add(bytes);
  }

  void _receive(Map<String, dynamic> message) {
    final id = message['id'];
    if (id == null) {
      // Logs/toasts are not account events and may echo private vendor input.
      if (!_events.isClosed &&
          const {
            'auth',
            'signIn',
            'recovered',
            'renewing',
            'load',
            'usage',
          }.contains(message['event'])) {
        _events.add(message);
      }
      return;
    }
    final fetch = _fetches[id];
    if (fetch != null) {
      fetch.receive(message);
      return;
    }
    final call = _calls.remove(id);
    if (call == null) return; // Late answer to a cancelled RPC.
    if (message['error'] != null) {
      call.completeError(const PluginRuntimeFailure('plugin_request_failed'));
    } else if (message.containsKey('result')) {
      call.complete(message['result']);
    } else {
      call.completeError(const PluginRuntimeFailure('invalid_host_response'));
    }
  }

  void _lost() {
    if (_dead) return;
    _dead = true;
    for (final call in _calls.values) {
      call.completeError(const PluginRuntimeFailure('host_closed'));
    }
    _calls.clear();
    for (final fetch in _fetches.values.toList()) {
      fetch.fail(const PluginRuntimeFailure('host_closed'));
    }
    unawaited(_events.close());
  }

  Future<bool> close({Duration timeout = const Duration(seconds: 30)}) async {
    try {
      await (_closeFuture ??= _close()).timeout(timeout);
      return true;
    } on TimeoutException {
      // The child still owns its OS lease and may be saving a rotated grant.
      // Do not kill it or permit a second writer merely to meet a UI deadline.
      return false;
    }
  }

  Future<void> _close() async {
    _closing = true;
    for (final fetch in _fetches.values.toList()) {
      await fetch.cancel();
    }
    // EOF asks the native host to finish active credential writes before exit.
    try {
      await _process.stdin.close();
    } on IOException {
      // A host that already exited may have closed the pipe first.
    }
    await _process.exitCode;
    _lost();
  }
}
