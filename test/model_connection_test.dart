import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/magpie_connection.dart';
import '../lib/model_connection.dart';
import '../lib/plugin_accounts.dart';
import '../lib/plugin_model_service.dart';
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PluginModelGrant _grant(String key, {String token = 'synthetic'}) =>
    PluginModelGrant(
      PluginAccount(
        key: key,
        active: true,
        facts: {'registrationId': key},
        models: [],
      ),
      token,
      true,
    );

String _listing(List<String> ids) => jsonEncode(magpiePluginList(ids));

void main() {
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
      expect(commands.where((c) => c == 'plugin list --json'), hasLength(1));
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
