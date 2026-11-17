import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/magpie_connection.dart';
import '../lib/model_connection.dart';
import '../lib/plugin_accounts.dart';
import '../lib/plugin_model_service.dart';
import '../lib/plugin_model_catalog.dart';
import 'magpie_fixture.dart';

class _Models extends ChangeNotifier implements PluginModelService {
  @override
  bool enabled = true;
  @override
  bool running = true;
  @override
  Uri? get endpoint => running ? Uri.parse('http://127.0.0.1:3426') : null;
  @override
  List<PluginModelGrant> grants = [_grant('one'), _grant('two')];
  void changed() => notifyListeners();
  @override
  Set<String> get legacyKeys => {};
  @override
  bool routingConnected = false;
  @override
  Map get routingSettings => {};
  @override
  List<PluginModel> get catalog =>
      pluginModelCatalog(grants, routingSettings, DateTime.now());
  @override
  Set<String> managedGroups = {};
  @override
  Future<void> saveManagedGroups(Set<String> value) async =>
      managedGroups = value;
  Future<void> Function()? beforeConnectionWrite;
  @override
  Future<void> markRoutingConnected() async {
    await beforeConnectionWrite?.call();
    routingConnected = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PluginModelGrant _grant(
  String key, {
  String token = 'synthetic',
  String? error,
  List<Map<String, dynamic>> models = const [],
}) => PluginModelGrant(
  PluginAccount(
    key: key,
    active: true,
    facts: {'registrationId': key, 'provider': 'qoder'},
    models: models,
    error: error,
  ),
  token,
  true,
);

String _listing(List<String> ids) {
  final value = magpiePluginList(ids, spec: '/bridge');
  (value['providers'] as List).first['accountId'] = ids.firstOrNull;
  return jsonEncode(value);
}

void main() {
  test('startup restores routing for a saved pre-routing connection', () async {
    final models = _Models()
      ..grants = [
        _grant(
          'one',
          models: [
            {
              'id': 'flash',
              'apiId': 'deepseek-v4.1-flash',
              'npm': '@ai-sdk/openai-compatible',
              'url': 'https://synthetic.invalid/v1',
            },
          ],
        ),
        _grant('new-account'),
      ];
    final commands = <List<String>>[];
    final applied = Completer<void>();
    var listings = 0;
    final connection = ModelConnection(
      models,
      '/bridge',
      client: MagpieConnection(
        run: (args, {input}) async {
          commands.add(args);
          if (args.join(' ') == 'plugin list --json')
            return _listing(listings++ == 0 ? ['one'] : ['one', 'new-account']);
          if (args.length > 1 && args[1] == 'options') applied.complete();
          return '';
        },
      ),
    );
    addTearDown(connection.dispose);
    addTearDown(models.dispose);
    connection.start();
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(models.routingConnected, isTrue);
    expect(applied.isCompleted, isTrue);
    final options = jsonDecode(
      commands.singleWhere((c) => c.length > 1 && c[1] == 'options').last,
    );
    expect(options['routes']['loongpass/auto'], 'group/loongpass-auto');
    expect(models.managedGroups, contains('loongpass-auto'));
    expect(connection.error, isNull);
    final count = commands.length;
    models.changed();
    await Future<void>.delayed(const Duration(milliseconds: 220));
    expect(commands.length, count);
  });

  test('startup leaves a new or unrelated connection unregistered', () async {
    final disabled = magpiePluginList(['one'], spec: '/bridge');
    disabled['plugins'][0]['off'] = true;
    final superseded = magpiePluginList(['one'], spec: '/bridge');
    superseded['loaded'][0]['servedBy'] = {'loongpass': '/other'};
    for (final output in [
      '[]',
      _listing(['other']),
      jsonEncode(disabled),
      jsonEncode(superseded),
      jsonEncode(magpiePluginList(['one'], spec: '/other')),
    ]) {
      final models = _Models();
      final commands = <List<String>>[];
      final connection = ModelConnection(
        models,
        '/bridge',
        client: MagpieConnection(
          run: (args, {input}) async {
            commands.add(args);
            if (args.join(' ') == 'plugin list --json') return output;
            throw StateError('Startup may only read the existing connection');
          },
        ),
      );
      connection.start();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(models.routingConnected, isFalse);
      expect(commands, [
        ['plugin', 'list', '--json'],
      ]);
      expect(connection.error, isNull);
      connection.dispose();
      models.dispose();
    }
  });

  test('startup cannot adopt a connection after its grants change', () async {
    final models = _Models();
    final listing = Completer<String>();
    final commands = <List<String>>[];
    final connection = ModelConnection(
      models,
      '/bridge',
      client: MagpieConnection(
        run: (args, {input}) async {
          commands.add(args);
          return listing.future;
        },
      ),
    );
    addTearDown(connection.dispose);
    addTearDown(models.dispose);
    connection.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    models.grants = [_grant('replacement')];
    models.changed();
    listing.complete(_listing(['one', 'two']));
    await Future<void>.delayed(const Duration(milliseconds: 220));
    expect(models.routingConnected, isFalse);
    expect(commands, everyElement(['plugin', 'list', '--json']));
  });

  test(
    'stopped service and disposal prevent startup connection writes',
    () async {
      final models = _Models()..running = false;
      final listing = Completer<String>();
      final commands = <List<String>>[];
      final connection = ModelConnection(
        models,
        '/bridge',
        client: MagpieConnection(
          run: (args, {input}) async {
            commands.add(args);
            return listing.future;
          },
        ),
      );
      addTearDown(models.dispose);
      connection.start();
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(commands, isEmpty);
      models.running = true;
      models.changed();
      await Future<void>.delayed(const Duration(milliseconds: 220));
      connection.dispose();
      listing.complete(_listing(['one', 'two']));
      await Future<void>.delayed(Duration.zero);
      expect(models.routingConnected, isFalse);
      expect(commands, [
        ['plugin', 'list', '--json'],
      ]);
    },
  );

  testWidgets(
    'startup retries after a transient connection intent write failure',
    (tester) async {
      final models = _Models();
      var writes = 0;
      models.beforeConnectionWrite = () async {
        if (writes++ == 0) throw StateError('transient store failure');
      };
      final connection = ModelConnection(
        models,
        '/bridge',
        client: MagpieConnection(
          run: (args, {input}) async =>
              args.contains('--json') ? _listing(['one', 'two']) : '',
        ),
      );
      addTearDown(connection.dispose);
      addTearDown(models.dispose);
      connection.start();
      await tester.pump(const Duration(milliseconds: 150));
      expect(connection.error, ModelConnectionFailure.saveFailed);
      expect(models.routingConnected, isFalse);
      await tester.pump(const Duration(seconds: 30));
      expect(models.routingConnected, isTrue);
      expect(connection.error, isNull);
    },
  );

  test(
    'startup rechecks disposal and source after saving connection intent',
    () async {
      for (final dispose in [false, true]) {
        final models = _Models();
        final saving = Completer<void>();
        final started = Completer<void>();
        models.beforeConnectionWrite = () {
          started.complete();
          return saving.future;
        };
        final commands = <List<String>>[];
        final connection = ModelConnection(
          models,
          '/bridge',
          client: MagpieConnection(
            run: (args, {input}) async {
              commands.add(args);
              return args.contains('--json') ? _listing(['one', 'two']) : '';
            },
          ),
        );
        connection.start();
        await started.future;
        if (dispose) {
          connection.dispose();
        } else {
          models.grants = [_grant('replacement')];
          models.changed();
        }
        saving.complete();
        await Future<void>.delayed(Duration.zero);
        expect(commands, [
          ['plugin', 'list', '--json'],
        ]);
        if (!dispose) connection.dispose();
        models.dispose();
      }
    },
  );

  test(
    'connected routing follows owner events and coalesces updates during sync',
    () async {
      final models = _Models()..routingConnected = true;
      final commands = <List<String>>[];
      final firstOptions = Completer<String>();
      final client = MagpieConnection(
        run: (args, {input}) async {
          commands.add(args);
          if (args.join(' ') == 'plugin list --json')
            return _listing(['one', 'two']);
          if (args.length > 1 &&
              args[1] == 'options' &&
              commands.where((c) => c.length > 1 && c[1] == 'options').length ==
                  1) {
            return firstOptions.future;
          }
          return '';
        },
      );
      final connection = ModelConnection(models, '/bridge', client: client)
        ..start();
      addTearDown(connection.dispose);
      addTearDown(models.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(connection.busy, isTrue);
      models.grants = [_grant('one', token: 'replacement')];
      models.changed();
      firstOptions.complete('');
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(connection.busy, isFalse);
      expect(connection.error, isNull);
      expect(
        commands.where((c) => c.length > 1 && c[1] == 'options'),
        hasLength(2),
      );
      expect(commands.where((c) => c.first == 'healthcheck'), isEmpty);
      final count = commands.length;
      models.changed();
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(commands.length, count);
      models.grants = [
        _grant('one', token: 'replacement', error: 'authorization_required'),
      ];
      models.changed();
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(connection.selectedAccounts, 0);
      expect(
        commands.where((c) => c.length > 1 && c[1] == 'options'),
        hasLength(3),
      );
    },
  );
  test(
    'closing during connection does not start a new diagnostic process',
    () async {
      final models = _Models();
      final saved = Completer<String>();
      final commands = <String>[];
      final connection = ModelConnection(
        models,
        '/bridge',
        client: MagpieConnection(
          run: (args, {input}) async {
            commands.add(args.join(' '));
            return args.contains('--json') ? saved.future : '';
          },
        ),
      );
      addTearDown(models.dispose);
      final connecting = connection.connect();
      await Future<void>.delayed(Duration.zero);
      connection.dispose();
      saved.complete(_listing(['one', 'two']));
      await connecting;
      expect(commands.where((c) => c == 'healthcheck'), isEmpty);
      // Installation discovery and post-login ownership verification belong to
      // the explicit connection; disposal must not add a healthcheck.
      expect(commands.where((c) => c == 'plugin list --json'), hasLength(2));
    },
  );
  test('snapshots are explicit and invalidated by grants, not balance notifications', () async {
    final models = _Models();
    var calls = 0;
    final connection = ModelConnection(
      models,
      '/bridge',
      client: MagpieConnection(
        run: (args, {input}) async {
          calls++;
          return args.first == 'healthcheck' ? '' : _listing(['one']);
        },
      ),
    );
    addTearDown(models.dispose);
    addTearDown(connection.dispose);
    expect(calls, 0);
    expect(connection.inspection, isNull);
    await connection.check();
    expect(connection.savedAccounts, 1);
    expect(connection.selectedAccounts, 2);
    expect(connection.checkedAt, isNotNull);
    models.changed();
    expect(connection.inspection, isNotNull);
    expect(calls, 2);
    models.grants = [_grant('one', token: 'new-registration')];
    models.changed();
    expect(connection.inspection, isNull);
    expect(connection.checkedAt, isNull);
    expect(calls, 2);
  });

  test('an in-flight result cannot certify changed accounts; duplicate check is coalesced', () async {
    final models = _Models();
    final pending = Completer<String>();
    var calls = 0;
    final connection = ModelConnection(
      models,
      '/bridge',
      client: MagpieConnection(
        run: (args, {input}) async {
          calls++;
          return args.first == 'healthcheck' ? '' : pending.future;
        },
      ),
    );
    addTearDown(models.dispose);
    addTearDown(connection.dispose);
    final check = connection.check();
    await Future<void>.delayed(Duration.zero);
    await connection.check();
    expect(connection.busy, isTrue);
    expect(calls, 2);
    models.running = false;
    models.changed();
    pending.complete(_listing(['one', 'two']));
    await check;
    expect(connection.inspection, isNull);
    expect(connection.error, ModelConnectionFailure.changed);
    expect(connection.busy, isFalse);
  });

  test(
    'save failure is recoverable and disposal suppresses late results',
    () async {
      final models = _Models();
      var fail = true;
      final pending = Completer<String>();
      final connection = ModelConnection(
        models,
        '/bridge',
        client: MagpieConnection(
          run: (args, {input}) async {
            if (fail) throw StateError('private upstream details');
            return args.first == 'healthcheck' ? '' : pending.future;
          },
        ),
      );
      addTearDown(models.dispose);
      await connection.connect();
      expect(connection.error, ModelConnectionFailure.saveFailed);
      fail = false;
      final check = connection.check();
      await Future<void>.delayed(Duration.zero);
      connection.dispose();
      pending.complete(_listing(['one']));
      await check;
      expect(connection.inspection, isNull);
    },
  );
}
