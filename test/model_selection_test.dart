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
    'retained models survive restart and filter the native catalog',
    () async {
      await service.retainModels({'deepseek-flash'});
      accounts.accounts.first.models.add({'id': 'glm-5.3'});
      expect(service.catalog.where((m) => m.enabled).map((m) => m.id), [
        'deepseek-flash',
      ]);
      await service.close();
      service = PluginModelService(accounts: accounts, store: store, port: 0);
      await service.start();
      expect(service.catalog.where((m) => m.enabled).map((m) => m.id), [
        'deepseek-flash',
      ]);
      await service.setEnabled(true);
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          service.endpoint!.resolve('/plugin/catalog'),
        );
        request.headers.set('authorization', 'Bearer synthetic-saved-0');
        final response = await request.close();
        expect(response.statusCode, 200);
        final data = jsonDecode(await utf8.decoder.bind(response).join());
        expect(data['models'], isEmpty);
        expect(data['publicModels'], isEmpty);
      } finally {
        client.close(force: true);
      }
      await service.setModelEnabled('MiniMax-M3', true);
      expect(service.catalog.where((m) => m.enabled).map((m) => m.id), [
        'MiniMax-M3',
        'deepseek-flash',
      ]);
    },
  );

  test(
    'selection writes are atomic and serialize with individual changes',
    () async {
      store.beforeWrite = () async =>
          throw const FileSystemException('synthetic');
      await expectLater(
        service.retainModels({'deepseek-flash'}),
        throwsA(isA<FileSystemException>()),
      );
      expect(service.catalog.every((m) => m.enabled), isTrue);
      store.beforeWrite = null;
      await Future.wait<void>([
        service.retainModels({'deepseek-flash'}),
        service.setModelEnabled('MiniMax-M3', true),
      ]);
      expect(service.catalog.every((m) => m.enabled), isTrue);
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
    await service.setModelEnabled('deepseek-flash', false);
    await service.close();
    account.models.addAll(savedModels);
    account.facts['provider'] = 'trae-cn';
    account.models.addAll([
      {'id': 'glm-5.3'},
      {'id': 'glm-5.3-max'},
    ]);
    service = PluginModelService(accounts: accounts, store: store, port: 0);
    await service.start();
    await service.retainModels({'glm-5.3'});
    final grouped = service.catalog.singleWhere((m) => m.id == 'glm-5.3');
    expect(grouped.enabled, isTrue);
    expect(grouped.availableAccounts, 0);
    expect(
      store.data['routing']['legacy']['models']['trae-cn/glm-5.3-max'],
      isFalse,
    );
  });
}
