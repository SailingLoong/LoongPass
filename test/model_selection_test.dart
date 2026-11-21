import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/plugin_model_service.dart';
import 'memory_account_store.dart';
import 'model_workspace_fixture.dart';

void main() {
  late WorkspaceFixtureAccounts accounts;
  late MemoryAccountStore store;
  late PluginModelService service;
  setUp(() async {
    accounts = WorkspaceFixtureAccounts();
    store = MemoryAccountStore('selection')
      ..data = {
        'version': 4,
        'enabled': false,
        'grants': {
          for (final account in accounts.accounts)
            account.key: {
              'enabled': true,
              'registrationId': account.registrationId,
              'token': 'synthetic-${account.key}',
            },
        },
      };
    service = PluginModelService(accounts: accounts, store: store, port: 0);
    await service.start();
  });
  tearDown(() async {
    await service.close();
    accounts.dispose();
  });

  test(
    'only published models pass native discovery, including after a restart',
    () async {
      await service.setModelPublished('deepseek-flash', true);
      accounts.accounts.first.models.add({'id': 'glm-5.3'});
      await service.close();
      service = PluginModelService(accounts: accounts, store: store, port: 0);
      await service.start();
      expect(service.catalog.where((m) => m.published).map((m) => m.id), [
        'deepseek-flash',
      ]);
      await service.setEnabled(true);
      final client = HttpClient();
      try {
        Future<List> nativeModels() async {
          final request = await client.getUrl(
            service.endpoint!.resolve('/plugin/catalog'),
          );
          request.headers.set('authorization', 'Bearer synthetic-saved-0');
          final response = await request.close();
          expect(response.statusCode, 200);
          return jsonDecode(await utf8.decoder.bind(response).join())['models'];
        }

        expect(await nativeModels(), isEmpty);
        await service.setModelPublished('MiniMax-M3', true);
        expect((await nativeModels()).map((m) => m['id']), ['MiniMax-M3']);
        await service.setModelPublished('MiniMax-M3', false);
        expect(await nativeModels(), isEmpty);
      } finally {
        client.close(force: true);
      }
    },
  );

  test('upgrade keeps Magpie choices, order and per-account controls over conflicting old Auto settings', () async {
    await service.close();
    store.data['routing'] = {
      'version': 3,
      'models': {'MiniMax-M3': true, 'deepseek-flash': false},
      'published': {'deepseek-flash': true},
      'order': ['deepseek-flash', 'MiniMax-M3'],
      'autoPriority': 'creditExpiry',
      'accounts': {
        'deepseek-flash': {'saved-13': false},
      },
    };
    service = PluginModelService(accounts: accounts, store: store, port: 0);
    await service.start();
    expect(service.catalog.map((m) => m.id), ['deepseek-flash', 'MiniMax-M3']);
    expect(
      service.catalog.where((m) => m.published).single.id,
      'deepseek-flash',
    );
    expect(
      service.catalog.first.bindings
          .singleWhere((b) => b.account.key == 'saved-13')
          .enabled,
      isFalse,
    );
    expect(service.routingSettings['autoPriority'], 'creditExpiry');
    expect(service.routingSettings.containsKey('models'), isFalse);
  });

  test(
    'the last native order survives restarts and missing accounts',
    () async {
      for (final id in ['deepseek-flash', 'MiniMax-M3']) {
        await service.setModelPublished(id, true);
      }
      await service.rememberPublishedOrder(['deepseek-flash', 'MiniMax-M3']);
      final account = accounts.accounts.first;
      account.models.add({'id': 'glm-5.3'});
      await service.setModelPublished('glm-5.3', true);
      await service.rememberPublishedOrder(['glm-5.3', 'MiniMax-M3']);
      await service.close();
      service = PluginModelService(accounts: accounts, store: store, port: 0);
      await service.start();
      expect(service.catalog.map((m) => m.id), [
        'glm-5.3',
        'MiniMax-M3',
        'deepseek-flash',
      ]);
    },
  );

  test(
    'failed publication is atomic and subsequent settings changes serialize',
    () async {
      store.beforeWrite = () async =>
          throw const FileSystemException('synthetic');
      await expectLater(
        service.setModelPublished('MiniMax-M3', true),
        throwsA(isA<FileSystemException>()),
      );
      expect(service.catalog.any((m) => m.published), isFalse);
      store.beforeWrite = null;
      await Future.wait([
        service.setModelPublished('deepseek-flash', true),
        service.setModelPublished('MiniMax-M3', true),
      ]);
      expect(service.catalog.every((m) => m.published), isTrue);
    },
  );

  test('editing with a missing catalog preserves legacy alias choices after restart', () async {
    await service.close();
    store.data['routing'] = {
      'models': {'trae-cn/glm-5.3-max': false},
      'accounts': {
        'glm-5.3': {'saved-0': false},
      },
    };
    final account = accounts.accounts.first;
    final savedModels = List<Map<String, dynamic>>.from(account.models);
    account.models.clear();
    service = PluginModelService(accounts: accounts, store: store, port: 0);
    await service.start();
    await service.setModelPublished('deepseek-flash', true);
    await service.close();
    account.models.addAll(savedModels);
    account.facts['provider'] = 'trae-cn';
    account.models.addAll([
      {'id': 'glm-5.3'},
      {'id': 'glm-5.3-max'},
    ]);
    service = PluginModelService(accounts: accounts, store: store, port: 0);
    await service.start();
    await service.setModelPublished('glm-5.3', true);
    final grouped = service.catalog.singleWhere((m) => m.id == 'glm-5.3');
    expect(grouped.published, isTrue);
    expect(grouped.availableAccounts, 0);
    expect(
      store.data['routing']['legacy']['models']['trae-cn/glm-5.3-max'],
      isFalse,
    );
  });
}
