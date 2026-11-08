import 'dart:async';
import 'dart:convert';

class PluginRuntimeFailure implements Exception {
  const PluginRuntimeFailure(this.code);
  final String code;
  @override
  String toString() => 'PluginRuntimeFailure($code)';
}

class PluginResponse {
  PluginResponse(this.status, this.headers, this.body);
  final int status;
  final Map<String, String> headers;
  final Stream<List<int>> body;
}

abstract interface class PluginFetch {
  Future<PluginResponse> get response;
  Future<void> cancel();
}

/// One host fetch. Its queue stays within the native byte-credit window until
/// the consumer reads it; a completed producer does not release its slot early.
class PluginStream implements PluginFetch {
  PluginStream({
    required this.credit,
    required this.abort,
    required this.release,
  }) {
    _headTimer = Timer(const Duration(minutes: 2), () {
      fail(const PluginRuntimeFailure('response_timeout'));
      abort();
    });
  }
  final void Function(int bytes) credit;
  final void Function() abort;
  final void Function() release;
  final _head = Completer<PluginResponse>();
  final _chunks = StreamController<List<int>>();
  late final Timer _headTimer;
  bool _terminal = false;
  bool _released = false;

  @override
  Future<PluginResponse> get response => _head.future;

  void receive(Map<String, dynamic> message) {
    if (_terminal) return;
    switch (message['event']) {
      case 'head':
        final status = message['status'];
        final headers = message['headers'];
        if (_head.isCompleted ||
            status is! int ||
            status < 100 ||
            status > 599 ||
            headers is! Map) {
          throw const FormatException('Invalid response head');
        }
        final safeHeaders = <String, String>{};
        for (final entry in headers.entries) {
          if (entry.key is! String || entry.value is! String)
            throw const FormatException();
          final key = (entry.key as String).toLowerCase();
          // Fetch has already decoded the response body.
          if (!const {
            'content-encoding',
            'content-length',
            'transfer-encoding',
            'connection',
          }.contains(key)) {
            safeHeaders[key] = entry.value as String;
          }
        }
        _headTimer.cancel();
        _head.complete(
          PluginResponse(status, Map.unmodifiable(safeHeaders), _body()),
        );
      case 'chunk':
        if (!_head.isCompleted || message['data'] is! String)
          throw const FormatException();
        final bytes = base64Decode(message['data'] as String);
        if (bytes.isEmpty || bytes.length > 65536)
          throw const FormatException();
        _chunks.add(bytes);
      default:
        if (message.containsKey('error')) {
          fail(const PluginRuntimeFailure('plugin_fetch_failed'));
        } else if (message.containsKey('result') && _head.isCompleted) {
          _terminal = true;
          unawaited(_chunks.close());
        } else {
          throw const FormatException('Incomplete response');
        }
    }
  }

  Stream<List<int>> _body() async* {
    try {
      await for (final bytes in _chunks.stream) {
        yield bytes;
        if (!_terminal && !_released) credit(bytes.length + 2048);
      }
    } finally {
      await cancel();
    }
  }

  void fail(PluginRuntimeFailure error) {
    if (_terminal) return;
    _terminal = true;
    _headTimer.cancel();
    if (_head.isCompleted) {
      _chunks.addError(error);
      unawaited(_chunks.close());
    } else {
      _head.completeError(error);
      unawaited(_chunks.close());
      _release();
    }
  }

  void _release() {
    if (_released) return;
    _released = true;
    release();
  }

  @override
  Future<void> cancel() async {
    if (_released) return;
    _headTimer.cancel();
    if (!_terminal) {
      _terminal = true;
      abort();
      if (!_head.isCompleted) {
        _head.completeError(const PluginRuntimeFailure('request_cancelled'));
      }
      unawaited(_chunks.close());
    }
    _release();
  }
}
