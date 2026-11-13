import 'dart:async';
import 'dart:io';

const _proxyNames = ['HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'NO_PROXY'];

/// Prepare the pinned Magpie host's environment before Bun starts. Ordinary
/// proxy variables must not reach Bun: its implicit proxy bypasses the host's
/// per-request direct/LAN routing. See upstream internal/plugin/host.go hostEnv
/// and internal/netproxy (MIT; runtime/vendor/magpie/LICENSE).
Future<Map<String, String>> pluginHostEnvironment(
  Map<String, String> environment, {
  String? operatingSystem,
  Future<String> Function(String, List<String>)? read,
}) async {
  final source = Map<String, String>.of(environment);
  String value(String key) =>
      [
        source[key],
        source[key.toLowerCase()],
        source['MAGPIE_$key'],
        source['MAGPIE_${key.toLowerCase()}'],
      ].whereType<String>().where((v) => v.trim().isNotEmpty).firstOrNull ??
      '';
  if (!_proxyNames.take(3).any((key) => value(key).trim().isNotEmpty)) {
    try {
      final settings = await _systemProxy(
        operatingSystem ?? Platform.operatingSystem,
        source,
        read ?? _read,
      );
      if (settings.proxy != null) {
        final bypass = <String>{'localhost', '127.0.0.1', '::1'};
        for (final entry in [value('NO_PROXY'), ...settings.bypass]) {
          for (var host in entry.split(',')) {
            host = host.trim();
            if (host.startsWith('*.')) host = host.substring(1);
            if (host.isNotEmpty && host != '<local>') bypass.add(host);
          }
        }
        for (final key in _proxyNames.take(3)) source[key] = settings.proxy!;
        source['NO_PROXY'] = bypass.join(',');
      }
    } catch (_) {
      // An unavailable OS setting must not prevent the credential owner starting.
    }
  }
  final result = <String, String>{
    for (final entry in source.entries)
      if (!_proxyNames.contains(
        entry.key.toUpperCase().replaceFirst(RegExp(r'^MAGPIE_'), ''),
      ))
        entry.key: entry.value,
  };
  for (final key in _proxyNames) {
    final setting = value(key);
    if (setting.isNotEmpty) result['MAGPIE_$key'] = setting;
  }
  return result;
}

Future<String> _read(String executable, List<String> arguments) async {
  final process = await Process.start(executable, arguments);
  final output = process.stdout
      .transform(systemEncoding.decoder)
      .join()
      .catchError((Object _) => '');
  final errors = process.stderr.drain<void>();
  try {
    if (await process.exitCode.timeout(const Duration(seconds: 10)) != 0)
      return '';
    return await output;
  } finally {
    process.kill();
    await errors;
  }
}

typedef _ProxySettings = ({String? proxy, List<String> bypass});

Future<_ProxySettings> _systemProxy(
  String platform,
  Map<String, String> environment,
  Future<String> Function(String, List<String>) read,
) async {
  if (platform == 'macos') {
    return _macProxy(await read('/usr/sbin/scutil', ['--proxy']));
  }
  if (platform == 'windows') {
    final root =
        environment.entries
            .where((e) => e.key.toLowerCase() == 'systemroot')
            .map((e) => e.value)
            .firstOrNull ??
        r'C:\Windows';
    return _windowsProxy(
      await read('$root\\System32\\reg.exe', [
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
      ]),
    );
  }
  return (proxy: null, bypass: <String>[]);
}

_ProxySettings _macProxy(String output) {
  final values = <String, String>{};
  final bypass = <String>[];
  var inList = false;
  for (final raw in output.split('\n')) {
    final line = raw.trim();
    if (line == '}') {
      inList = false;
      continue;
    }
    final at = line.indexOf(' : ');
    if (at < 0) continue;
    final key = line.substring(0, at), value = line.substring(at + 3);
    if (inList) {
      bypass.add(value);
    } else if (key == 'ExceptionsList') {
      inList = true;
    } else {
      values[key] = value;
    }
  }
  for (final kind in ['HTTPS', 'HTTP']) {
    final host = values['${kind}Proxy'];
    if (values['${kind}Enable'] != '1' || host == null || host.isEmpty)
      continue;
    final portText = values['${kind}Port'];
    final port = portText == null ? 80 : int.tryParse(portText);
    if (port == null || port < 1 || port > 65535) continue;
    final proxy = _httpProxy(
      Uri(scheme: 'http', host: host, port: port).toString(),
    );
    if (proxy != null) return (proxy: proxy, bypass: bypass);
  }
  return (proxy: null, bypass: <String>[]);
}

_ProxySettings _windowsProxy(String output) {
  final values = {
    for (final m in RegExp(
      r'^\s*(ProxyEnable|ProxyServer|ProxyOverride)\s+REG_\w+\s+(.+)$',
      multiLine: true,
    ).allMatches(output))
      m[1]!: m[2]!.trim(),
  };
  if (int.tryParse(values['ProxyEnable'] ?? '') != 1)
    return (proxy: null, bypass: <String>[]);
  final server = values['ProxyServer'] ?? '';
  String? proxy;
  if (server.contains('=')) {
    final protocols = <String, String>{};
    for (final part in server.split(';')) {
      final at = part.indexOf('=');
      if (at > 0)
        protocols[part.substring(0, at).trim().toLowerCase()] = part
            .substring(at + 1)
            .trim();
    }
    proxy = _httpProxy(protocols['https']) ?? _httpProxy(protocols['http']);
  } else {
    proxy = _httpProxy(server);
  }
  return (proxy: proxy, bypass: (values['ProxyOverride'] ?? '').split(';'));
}

String? _httpProxy(String? value) {
  if (value == null || value.isEmpty) return null;
  try {
    final uri = Uri.parse(value.contains('://') ? value : 'http://$value');
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.port < 1 ||
        uri.port > 65535 ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment)
      return null;
    return uri.toString().replaceFirst(RegExp(r'/$'), '');
  } on FormatException {
    return null;
  }
}
