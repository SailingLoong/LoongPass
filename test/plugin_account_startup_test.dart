import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/plugin_accounts.dart';
import '../lib/plugin_model_service.dart';
import '../lib/plugin_runtime.dart';
import 'memory_account_store.dart';

class _Host implements PluginRuntime {
  final catalog = Completer<void>();
  final catalogRequested = Completer<void>();
  final slowUsage = Completer<void>();
  final usageCalls = <String>[];
  bool offline = false;
  bool unreadable = false;
  int listings = 0;
  bool holdAllUsage = false;
  final limits = <String, int>{};

  @override
  final providerIds = ['slow', 'fast'];
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  final keys = ['slow#1', 'slow#2', 'fast#1'];

  @override
  Future<Object?> call(
    String method,
    Map<String, Object?> params, {
    Duration timeout = const Duration(seconds: 30),
    Future<void>? cancellation,
  }) async {
    switch (method) {
      case 'authSnapshot':
        if (unreadable) throw StateError('unreadable local data');
        return <String, dynamic>{
          for (final key in keys)
            key: {'type': 'oauth', 'uid': key, 'accountId': key},
        };
      case 'providers':
        final account = params['account'];
        final quiet =
            account == null &&
            providerIds.every(
              (id) => (params['off'] as List? ?? []).contains(id),
            );
        if (account == null) listings++;
        final listed = keys
            .where((key) => account == null || key == account)
            .toList();
        if (!quiet) {
          if (!catalogRequested.isCompleted) catalogRequested.complete();
          await catalog.future;
          if (offline) throw StateError('offline');
        }
        return [
          for (final id in providerIds.where(
            (id) =>
                account == null || (account as String).split('#').first == id,
          ))
            {
              'id': id,
              'usage': true,
              'maxAccounts': limits[id] ?? 0,
              'models': [
                {'id': 'model', 'url': 'https://example.invalid'},
              ],
              'accounts': [
                for (final key in listed.where((key) => key.startsWith('$id#')))
                  {'key': key},
              ],
            },
        ];
      case 'load':
        return {'baseURL': 'https://example.invalid'};
      case 'usage':
        final key = params['account'] as String;
        usageCalls.add(key);
        if (holdAllUsage || key == 'slow#1') await slowUsage.future;
        return {
          'windows': [
            {'balance': 12.5, 'unit': 'credits'},
          ],
        };
      default:
        throw UnsupportedError(method);
    }
  }

  void release() {
    if (!catalog.isCompleted) catalog.complete();
    if (!slowUsage.isCompleted) slowUsage.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Host host;
  late PluginAccounts accounts;
  late MemoryAccountStore facts;

  setUp(() {
    host = _Host();
    facts = MemoryAccountStore('facts')
      ..data = {
        'accounts': {
          for (final key in host.keys)
            key: {
              'provider': key.split('#').first,
              'uid': key,
              'realm': '',
              'registrationId': key,
              'label': 'Saved $key',
            },
        },
      };
    accounts = PluginAccounts(
      runtime: host,
      directory: '',
      store: facts,
      enabledProviders: host.providerIds.toSet(),
    );
    addTearDown(() async {
      host.release();
      await accounts.close();
    });
  });

  test(
    'saved accounts are ready while provider discovery is blocked',
    () async {
      var ready = false;
      final startup = accounts.start().then((_) => ready = true);
      try {
        await host.catalogRequested.future;
        await pumpEventQueue();
        expect(ready, isTrue);
        expect(
          accounts.accounts.map((a) => a.label),
          host.keys.map((k) => 'Saved $k'),
        );
        expect(
          accounts.accounts.every(
            (a) => a.active && a.queriedAt == null && a.usage == null,
          ),
          isTrue,
        );
        final refresh = accounts.refresh();
        host.release();
        await refresh;
        expect(host.listings, 1);
        expect(
          accounts.accounts.every((a) => a.models.single['id'] == 'model'),
          isTrue,
        );
      } finally {
        host.release();
        await startup;
      }
    },
  );

  test(
    'another provider publishes its balance while the first one is pending',
    () async {
      host.limits['slow'] = 1;
      final observed = <String>{};
      accounts.addListener(() {
        observed.addAll(
          accounts.accounts.where((a) => a.queriedAt != null).map((a) => a.key),
        );
      });
      host.catalog.complete();
      final startup = accounts.start();
      try {
        await host.catalogRequested.future;
        await pumpEventQueue();
        expect(observed, {'fast#1'});
        expect(host.usageCalls, contains('slow#1'));
        expect(host.usageCalls, isNot(contains('slow#2')));
        final fast = accounts.accounts.singleWhere((a) => a.key == 'fast#1');
        expect(fast.usage!['windows'].single, {
          'balance': 12.5,
          'unit': 'credits',
        });
      } finally {
        host.release();
        await startup;
        await accounts.refresh();
      }
    },
  );

  test(
    'account queries share three slots and at most two per source',
    () async {
      host.keys.addAll(['slow#3', 'fast#2', 'fast#3']);
      host.holdAllUsage = true;
      host.catalog.complete();
      final startup = accounts.start();
      try {
        await host.catalogRequested.future;
        await pumpEventQueue();
        expect(host.usageCalls.toSet(), {'slow#1', 'slow#2', 'fast#1'});
      } finally {
        host.release();
        await startup;
        await accounts.refresh();
      }
      expect(host.usageCalls.toSet(), host.keys.toSet());
    },
  );

  test(
    'an offline catalog keeps local identities and recovers on refresh',
    () async {
      host.offline = true;
      host.release();
      await accounts.start();
      await expectLater(accounts.refresh(), throwsStateError);
      expect(accounts.error, 'catalog_unavailable');
      expect(
        accounts.accounts.every((a) => a.active && a.usage == null),
        isTrue,
      );
      host.offline = false;
      await accounts.refresh();
      expect(accounts.error, isNull);
      expect(accounts.accounts.every((a) => a.queriedAt != null), isTrue);
      host.unreadable = true;
      await expectLater(accounts.refresh(), throwsStateError);
      expect(accounts.accounts.any((a) => a.active), isFalse);
    },
  );

  test(
    'authorization during startup is included in the next catalog',
    () async {
      await accounts.start();
      await host.catalogRequested.future;
      host.keys.add('fast#new');
      final saved = accounts.authorizationSaved('fast#new');
      await pumpEventQueue();
      host.release();
      await saved;
      expect(host.listings, 2);
      final account = accounts.accounts.singleWhere((a) => a.key == 'fast#new');
      expect(account.active, isTrue);
      expect(account.models.single['id'], 'model');
      expect(account.queriedAt, isNotNull);
    },
  );

  test('the model bridge reports a pending catalog until the first refresh finishes', () async {
    final settings = MemoryAccountStore('models')
      ..data = {
        'version': 4,
        'enabled': true,
        'grants': {
          'fast#1': {
            'token': 'test-only',
            'enabled': true,
            'registrationId': 'fast#1',
          },
        },
      };
    final models = PluginModelService(
      accounts: accounts,
      store: settings,
      port: 0,
    );
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await models.close();
    });
    Future<int> readCatalog() async {
      final request = await client.getUrl(
        models.endpoint!.resolve('/plugin/catalog'),
      );
      request.headers.set('authorization', 'Bearer test-only');
      final response = await request.close();
      final body = jsonDecode(await utf8.decoder.bind(response).join());
      if (response.statusCode == 503) expect(body['error'], 'catalog_pending');
      return response.statusCode;
    }

    final startup = accounts.start();
    try {
      await host.catalogRequested.future;
      await models.start();
      expect(await readCatalog(), 503);
    } finally {
      host.release();
      await startup;
    }
    await accounts.refresh();
    expect(await readCatalog(), 200);
  });
}
