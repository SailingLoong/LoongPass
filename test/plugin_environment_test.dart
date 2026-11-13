import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/plugin_environment.dart';

const macSettings = '''<dictionary> {
  HTTPEnable : 1
  HTTPProxy : 127.0.0.1
  HTTPPort : 8080
  HTTPSEnable : 1
  HTTPSProxy : ::1
  HTTPSPort : 8081
  ExceptionsList : <array> {
    0 : *.local
    1 : 192.168.0.0/16
  }
}''';

void main() {
  Future<Map<String, String>> mac(
    Map<String, String> env, [
    String settings = macSettings,
  ]) => pluginHostEnvironment(
    env,
    operatingSystem: 'macos',
    read: (_, _) async => settings,
  );

  test(
    'desktop proxy uses the native host namespace and preserves bypasses',
    () async {
      final env = await mac({
        'NO_PROXY': 'private.example',
        'PATH': '/usr/bin',
      });
      expect(env['MAGPIE_HTTPS_PROXY'], 'http://[::1]:8081');
      expect(env['MAGPIE_HTTP_PROXY'], 'http://[::1]:8081');
      expect(
        env['MAGPIE_NO_PROXY'],
        'localhost,127.0.0.1,::1,private.example,.local,192.168.0.0/16',
      );
      expect(env['PATH'], '/usr/bin');
      expect(env.containsKey('HTTPS_PROXY'), isFalse);
      expect(env.containsKey('NO_PROXY'), isFalse);
    },
  );

  test(
    'explicit proxy is transferred before Bun starts without reading the OS',
    () async {
      for (final key in [
        'HTTPS_PROXY',
        'http_proxy',
        'ALL_PROXY',
        'MAGPIE_HTTP_PROXY',
      ]) {
        var reads = 0;
        final env = await pluginHostEnvironment(
          {key: 'http://chosen.example:9000'},
          operatingSystem: 'macos',
          read: (_, _) async {
            reads++;
            return macSettings;
          },
        );
        expect(
          env[key.startsWith('MAGPIE_') ? key : 'MAGPIE_${key.toUpperCase()}'],
          'http://chosen.example:9000',
        );
        expect(reads, 0);
        expect(
          env.keys.any(
            (k) => RegExp(
              r'^(https?|all|no)_proxy$',
              caseSensitive: false,
            ).hasMatch(k),
          ),
          isFalse,
        );
      }
    },
  );

  test('bypass-all remains effective when the OS supplies a proxy', () async {
    for (final key in ['NO_PROXY', 'no_proxy']) {
      expect(
        (await mac({key: '*'}))['MAGPIE_NO_PROXY']!.split(','),
        contains('*'),
      );
    }
  });

  test(
    'an empty uppercase variable does not hide an explicit lowercase proxy',
    () async {
      final env = await mac({
        'HTTPS_PROXY': '',
        'https_proxy': 'http://chosen.example:9000',
      });
      expect(env['MAGPIE_HTTPS_PROXY'], 'http://chosen.example:9000');
    },
  );

  test(
    'disabled malformed unsupported or unreadable settings preserve startup',
    () async {
      for (final value in [
        '',
        macSettings.replaceAll('Enable : 1', 'Enable : 0'),
        'HTTPEnable : 1\nHTTPProxy : 127.0.0.1\nHTTPPort : 99999',
        'SOCKSEnable : 1\nSOCKSProxy : 127.0.0.1\nSOCKSPort : 1080',
      ]) {
        expect(await mac({'PATH': '/bin'}, value), {'PATH': '/bin'});
      }
      expect(
        await pluginHostEnvironment(
          {},
          operatingSystem: 'windows',
          read: (_, _) async => throw const FileSystemException('denied'),
        ),
        isEmpty,
      );
      expect(
        await pluginHostEnvironment(
          {},
          operatingSystem: 'linux',
          read: (_, _) async => throw StateError('must not read'),
        ),
        isEmpty,
      );
    },
  );

  test('Windows manual proxy respects enablement protocol selection and exclusions', () async {
    const registry = '''HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings
    ProxyEnable    REG_DWORD    0x1
    ProxyServer    REG_SZ    http=localhost:8080;https=proxy.example:8081;socks=localhost:1080
    ProxyOverride    REG_SZ    <local>;*.internal;10.0.0.0/8''';
    Future<Map<String, String>> windows(String settings) =>
        pluginHostEnvironment(
          {},
          operatingSystem: 'windows',
          read: (_, _) async => settings,
        );
    final env = await windows(registry);
    expect(env['MAGPIE_HTTPS_PROXY'], 'http://proxy.example:8081');
    expect(
      env['MAGPIE_NO_PROXY'],
      'localhost,127.0.0.1,::1,.internal,10.0.0.0/8',
    );
    expect(await windows(registry.replaceFirst('0x1', '0x0')), isEmpty);
    expect(
      (await windows(
        registry.replaceFirst(
          RegExp(r'ProxyServer    REG_SZ    .*'),
          'ProxyServer    REG_SZ    localhost:8082',
        ),
      ))['MAGPIE_HTTP_PROXY'],
      'http://localhost:8082',
    );
    expect(
      (await mac(
        {},
        macSettings.replaceFirst('HTTPSEnable : 1', 'HTTPSEnable : 0'),
      ))['MAGPIE_HTTPS_PROXY'],
      'http://127.0.0.1:8080',
    );
  });

  test(
    'actual pinned host forwards public requests and keeps loopback direct',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'loongpass-proxy-',
      );
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final direct = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final proxied = <Uri>[];
      var directCalls = 0;
      proxy.listen((request) async {
        proxied.add(request.uri);
        request.response.write('via-proxy');
        await request.response.close();
      });
      direct.listen((request) async {
        directCalls++;
        request.response.write('direct');
        await request.response.close();
      });
      Process? child;
      try {
        final source = File('${directory.path}/probe.mjs');
        await source.writeAsString('''
import { writeFileSync } from 'node:fs';
await import(${jsonEncode(File('runtime/vendor/magpie/host.js').absolute.uri.toString())});
const bodies = [];
for (const url of ['http://public.example.invalid/test', 'http://127.0.0.1:${direct.port}/test']) {
  bodies.push(await (await fetch(url, {signal: AbortSignal.timeout(5000)})).text());
}
writeFileSync('result.json', JSON.stringify(bodies));
process.exit(0);
''');
        final inherited = {...Platform.environment}
          ..removeWhere((key, _) => key.toUpperCase().contains('PROXY'));
        inherited['HTTP_PROXY'] = 'http://127.0.0.1:${proxy.port}';
        final environment = await pluginHostEnvironment(inherited);
        child = await Process.start(
          Platform.environment['LOONGPASS_BUN'] ?? 'bun',
          [File('runtime/launcher.mjs').absolute.path, source.path],
          workingDirectory: directory.path,
          environment: environment,
          includeParentEnvironment: false,
        );
        final errors = child.stderr.transform(utf8.decoder).join();
        final output = child.stdout.drain<void>();
        expect(
          await child.exitCode.timeout(const Duration(seconds: 10)),
          0,
          reason: await errors,
        );
        await output;
        expect(
          jsonDecode(
            await File('${directory.path}/result.json').readAsString(),
          ),
          ['via-proxy', 'direct'],
        );
        expect(proxied.map((u) => u.host), ['public.example.invalid']);
        expect(directCalls, 1);
      } finally {
        child?.kill();
        await child?.stdin.close();
        await proxy.close(force: true);
        await direct.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );
}
