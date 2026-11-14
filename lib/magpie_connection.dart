import 'dart:convert';
import 'dart:io';

import 'plugin_model_service.dart';

/// Native observations only. Saved account IDs do not certify inference.
class MagpieInspection {
  const MagpieInspection({
    required this.executableFound,
    this.gatewayReady,
    this.accountIds,
  });
  final bool executableFound;
  final bool? gatewayReady;
  final Set<String>? accountIds;
}

/// Uses Magpie's supported installation and authorization commands. Secrets
/// travel on stdin, never shell commands, process arguments or diagnostics.
class MagpieConnection {
  MagpieConnection({
    Future<String> Function(List<String>, {String? input})? run,
    Future<List<Map<String, dynamic>>> Function()? readProviders,
    Future<String> Function()? locateExecutable,
  }) : _command = run,
       _readProviders = readProviders,
       _locateExecutable = locateExecutable;
  final Future<String> Function(List<String>, {String? input})? _command;
  final Future<List<Map<String, dynamic>>> Function()? _readProviders;
  final Future<String> Function()? _locateExecutable;

  /// Explicit diagnostics use native commands; no vendor request is sent here.
  Future<MagpieInspection> inspect() async {
    String? executable;
    if (_command == null) {
      try {
        executable = await _executable();
      } catch (_) {
        return const MagpieInspection(executableFound: false);
      }
    }
    final command =
        _command ??
        (List<String> args, {String? input}) => _run(
          executable!,
          args,
          input: input,
          // Native plugin load and model-list hooks each have their own
          // 20-second budget. Let that bounded fallback finish before ours.
          timeout: args.first == 'healthcheck'
              ? const Duration(seconds: 10)
              : const Duration(minutes: 2),
        );
    var gatewayReady = false;
    Set<String>? accountIds;
    try {
      await command(['healthcheck']);
      gatewayReady = true;
    } catch (_) {}
    try {
      accountIds = _accountIds(await command(['plugin', 'list', '--json']));
    } catch (_) {}
    return MagpieInspection(
      executableFound: true,
      gatewayReady: gatewayReady,
      accountIds: accountIds == null ? null : Set.unmodifiable(accountIds),
    );
  }

  static Set<String> _accountIds(String output) {
    final value = jsonDecode(output);
    // Magpie returns [] (rather than an object) with no installed plugins.
    if (value is List && value.isEmpty) return {};
    if (value is! Map || value['providers'] is! List)
      throw const FormatException('Unknown Magpie plugin list');
    final providers = value['providers'] as List;
    if (providers.any((p) => p is! Map || p['id'] is! String))
      throw const FormatException('Unknown Magpie provider');
    final own = providers.where((p) => p['id'] == 'loongpass').firstOrNull;
    if (own == null) return {};
    // Native keepUnloaded retains cached provider/account rows when a plugin
    // is disabled or fails to load. Only its current owner can certify them.
    final spec = own['spec'];
    final installed = (value['plugins'] as List?)
        ?.whereType<Map>()
        .where((p) => p['spec'] == spec)
        .firstOrNull;
    final loaded = (value['loaded'] as List?)
        ?.whereType<Map>()
        .where((p) => p['spec'] == spec)
        .firstOrNull;
    if (spec is! String ||
        spec.isEmpty ||
        installed == null ||
        !{null, false}.contains(installed['off']) ||
        loaded == null ||
        !{null, ''}.contains(loaded['error']) ||
        loaded['provides'] is! List ||
        !(loaded['provides'] as List).contains('loongpass') ||
        (loaded['servedBy'] != null &&
            (loaded['servedBy'] is! Map ||
                !{null, spec}.contains(loaded['servedBy']['loongpass']))))
      throw const FormatException('Current LoongPass plugin not confirmed');
    final accounts = own['accounts'];
    if (accounts == null && own['signedIn'] == false) return {};
    if (accounts is! List ||
        accounts.any(
          (a) =>
              a is! Map ||
              a['accountId'] is! String ||
              (a['accountId'] as String).isEmpty,
        ))
      throw const FormatException('Unknown Magpie accounts');
    return {for (final a in accounts) a['accountId'] as String};
  }

  Future<void> connect(
    String bridgePath,
    Uri endpoint,
    List<PluginModelGrant> grants, {
    Set<String> legacyKeys = const {},
    Future<void> Function(List<Map<String, dynamic>>)? saveBackup,
  }) async {
    final selected = grants
        .where((g) => g.enabled && g.account.active)
        .toList();
    if (selected.isEmpty) throw StateError('No enabled account');
    final command =
        _command ??
        (List<String> args, {String? input}) async =>
            _run(await _executable(), args, input: input);
    await command(['plugin', 'add', bridgePath]);
    for (final grant in selected) {
      if ([
        grant.account.key,
        grant.token,
      ].any((v) => v.isEmpty || v.contains(RegExp(r'[\r\n]'))))
        throw const FormatException('Invalid account grant');
      await command([
        'plugin',
        'login',
        'loongpass',
        'api',
      ], input: '$endpoint\n${grant.account.key}\n${grant.token}\n');
    }
    // Native structured output is also the capability check. A successful
    // process exit alone does not prove every selected account was saved.
    final saved = _accountIds(await command(['plugin', 'list', '--json']));
    if (selected.any((g) => !saved.contains(g.account.key)))
      throw StateError('Magpie did not retain every account');

    if (legacyKeys.isEmpty) return;
    final previous = await (_readProviders ?? _installedProviders)();
    final retired = previous.where((p) {
      final id = p['id'];
      if (id is! String ||
          !(id == 'loongpass' || id.startsWith('loongpass-')) ||
          !legacyKeys.contains(p['key']))
        return false;
      final urls = ['url', 'anthropic', 'responses', 'gemini']
          .map((k) => p[k])
          .whereType<String>()
          .where((v) => v.isNotEmpty)
          .toList();
      return urls.isNotEmpty &&
          urls.every((value) {
            final uri = Uri.tryParse(value);
            return uri != null &&
                uri.scheme == 'http' &&
                uri.userInfo.isEmpty &&
                {'127.0.0.1', 'localhost', '::1'}.contains(uri.host) &&
                uri.port == endpoint.port;
          });
    }).toList();
    if (retired.isEmpty) return;
    if (saveBackup == null) throw StateError('Connection backup unavailable');
    await saveBackup(retired);
    for (final row in retired) {
      // Magpie owns removal, group resolution, and moving affected clients to
      // a model still served. Never rewrite its or a client's settings here.
      await command(['provider', 'rm', row['id']]);
    }
  }

  Future<List<Map<String, dynamic>>> _installedProviders() async {
    // Installed layouts only. Portable Magpie chooses its own data directory;
    // never use the installed profile to authorize deleting a portable row.
    var location = File(await _executable()).absolute.parent;
    if (Platform.isMacOS && location.path.endsWith('.app/Contents/MacOS'))
      location = location.parent.parent.parent;
    if (await File('${location.path}/.portable').exists() ||
        await Directory('${location.path}/data').exists())
      return [];
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    final home =
        Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    if (home == null) return [];
    final directory = xdg != null && Directory(xdg).isAbsolute
        ? xdg
        : '$home/.config';
    final file = File('$directory/magpie/providers.json');
    if (!await file.exists()) return [];
    if (await file.length() > 32 << 20)
      throw const FormatException('Provider document too large');
    final value = jsonDecode(await file.readAsString());
    if (value is! Map || value['providers'] is! List)
      throw const FormatException('Unknown Magpie provider document');
    return [
      for (final row in value['providers']) Map<String, dynamic>.from(row),
    ];
  }

  Future<String> _executable() async {
    if (_locateExecutable != null) return _locateExecutable();
    final candidates = <String>[
      for (final directory in (Platform.environment['PATH'] ?? '').split(
        Platform.isWindows ? ';' : ':',
      ))
        if (directory.isNotEmpty)
          '$directory/${Platform.isWindows ? 'magpie.exe' : 'magpie'}',
      if (Platform.isMacOS) ...[
        '/Applications/Magpie.app/Contents/MacOS/magpie',
        '${Platform.environment['HOME']}/Applications/Magpie.app/Contents/MacOS/magpie',
      ],
    ];
    for (final path in candidates) {
      if (await File(path).exists()) return path;
    }
    throw StateError('Magpie executable unavailable');
  }

  Future<String> _run(
    String executable,
    List<String> arguments, {
    String? input,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final child = await Process.start(
      executable,
      arguments,
      environment: {'NO_COLOR': '1'},
    );
    final output = child.stdout
            .fold<List<int>>(<int>[], (bytes, chunk) {
              if (bytes.length + chunk.length > 16 << 20) {
                child.kill();
                throw const FormatException('Magpie output too large');
              }
              bytes.addAll(chunk);
              return bytes;
            })
            .then(utf8.decode),
        errors = child.stderr.drain<void>();
    if (input != null) child.stdin.write(input);
    await child.stdin.close();
    try {
      final results = await Future.wait<Object?>([
        child.exitCode,
        output,
        errors,
      ], eagerError: true).timeout(timeout);
      if (results[0] != 0) throw StateError('Magpie connection was not saved');
      return results[1] as String;
    } finally {
      child.kill();
    }
  }
}
