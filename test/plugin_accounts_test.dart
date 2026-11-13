import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/plugin_runtime.dart';
import '../lib/plugin_accounts.dart';
import '../lib/plugin_sign_in.dart';
import 'memory_account_store.dart';

void main() {
  _identityTests();
  test(
    'account snapshots use native catalog and keep credentials out of UI facts',
    () async {
      final root = await Directory.systemTemp.createTemp('loongpass-accounts-');
      final runtime = await PluginRuntime.start(
        executable: Platform.environment['LOONGPASS_BUN'] ?? 'bun',
        hostPath: File('runtime/vendor/magpie/host.js').absolute.path,
        launcherPath: File('runtime/launcher.mjs').absolute.path,
        directory: root.path,
        plugins: [
          {
            'spec': 'fixture',
            'target': File('test/fixtures/native_plugin.mjs').absolute.path,
          },
        ],
      );
      final store = MemoryAccountStore('fixture');
      final accounts = PluginAccounts(
        runtime: runtime,
        directory: root.path,
        store: store,
        enabledProviders: {'fixture'},
      );
      try {
        await runtime.call('import', {
          'provider': 'fixture',
          'key': 'fixture#a',
          'auth': {
            'type': 'oauth',
            'uid': 'official-a',
            'accountId': 'Account A',
            'access': 'secret-access',
            'refresh': '',
            'expires': 0,
          },
        });
        await accounts.start();
        final account = accounts.accounts.single;
        expect(account.key, 'fixture#a');
        expect(account.uid, 'official-a');
        expect(account.models.single['id'], 'fixture-model');
        expect(account.models.single['npm'], '@ai-sdk/openai-compatible');
        expect(account.models.single['url'], 'https://fixture.invalid/v1');
        expect(jsonEncode(store.data), isNot(contains('secret-access')));
        expect(jsonEncode(account.models), isNot(contains('secret-access')));
        final registration = account.registrationId;
        await accounts.setAutomatic(account.key, false);
        await accounts.refresh();
        expect(accounts.accounts.single.automatic, false);
        expect(accounts.accounts.single.registrationId, registration);
        expect(
          (await accounts.currentCredential(account.key))['access'],
          'secret-access',
        );
        final login = PluginSignIn(
          runtime,
          onSaved: accounts.authorizationSaved,
        );
        final started = await login.begin('fixture', 0, {});
        expect(started['url'], 'https://fixture.invalid/login');
        final key = await login.finish();
        expect(
          accounts.accounts.firstWhere((a) => a.key == key).uid,
          'signed-in',
        );
        expect(
          (await accounts.currentCredential(key))['access'],
          'signed-access',
        );
        expect(jsonEncode(store.data), isNot(contains('signed-access')));
      } finally {
        await accounts.close();
        await runtime.close();
        await root.delete(recursive: true);
      }
    },
  );
}

class _IdentityHarness {
  _IdentityHarness(
    this.directory,
    this.runtime,
    this.store,
    this.accounts,
    this.provider,
    this.auth,
  );
  final Directory directory;
  final PluginRuntime runtime;
  final MemoryAccountStore store;
  final PluginAccounts accounts;
  final String provider;
  Map<String, dynamic> auth;
  String get key => '$provider#synthetic';
  File get callsFile => File('${directory.path}/calls');
  List<String> get calls =>
      callsFile.existsSync() ? callsFile.readAsLinesSync() : [];
  Future<void> clearCalls() => callsFile.writeAsString('');
  Future<void> control(Map<String, dynamic> value) =>
      File('${directory.path}/control.json').writeAsString(jsonEncode(value));
  Future<void> replace(Map<String, dynamic> fields) async {
    auth = {...auth, ...fields};
    await runtime.call('import', {
      'provider': provider,
      'key': key,
      'auth': auth,
    });
  }

  Future<String> saved() =>
      File('${directory.path}/plugin-auth.json').readAsString();
  Future<void> close() async {
    await accounts.close();
    await runtime.close();
    await directory.delete(recursive: true);
  }

  static Future<_IdentityHarness> open({
    String provider = 'fixture',
    Map<String, dynamic> auth = const {},
    Map<String, dynamic>? facts,
    bool start = true,
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'loongpass-account-identity-',
    );
    final fixture = File('${directory.path}/fixture.mjs');
    await fixture.writeAsString('''
      import {appendFileSync,existsSync,readFileSync,writeFileSync} from 'node:fs';
      globalThis.fetch = async () => { throw new Error('No network in account identity tests'); };
      const control = () => existsSync('control.json') ? JSON.parse(readFileSync('control.json','utf8')) : {};
      const note = name => appendFileSync('calls', name + '\\n');
      export const Fixture = async ({client}, options) => ({
        auth: {
          provider: options.provider,
          methods: [
            {type:'api',label:'Raw key',prompts:[{type:'text',key:'email'},{type:'text',key:'site'}]},
            {type:'api',label:'Authorized key',authorize:async inputs => {
              writeFileSync('inputs.json',JSON.stringify(inputs));
              if (inputs.email !== 'native@example.invalid') return {type:'failed',error:'Email was changed'};
              return {type:'success',metadata:{fromPlugin:'preserved'}};
            }},
            {type:'api',label:'API method returning OAuth',authorize:async () => ({type:'success',access:'official-token',refresh:'',expires:0,uid:'official-oauth',accountId:'official-account'})},
          ],
          refreshLead:0,
          refresh:async () => {note('refresh');return {access:'renewed',expires:Date.now()+3600000,...control().refresh};},
          loader:async getAuth => {
            note('load');
            const a=await getAuth();
            if(control().load) await client.auth.set({path:{id:options.provider},body:{...a,...control().load}});
            if(control().loadThrows) throw new Error('private-loader-detail');
            return {baseURL:'https://fixture.invalid/v1',apiKey:'fake'};
          },
          usage:async getAuth => {
            note('usage');
            const a=await getAuth();
            if(control().usage) await client.auth.set({path:{id:options.provider},body:{...a,...control().usage}});
            if(control().usageThrows) throw new Error('private-transport-detail');
            if(control().usageResult) return control().usageResult;
            return {windows:[{name:'Credits',amount:1.25,limit:100.125,unit:'credits'}]};
          },
        },
        provider:{id:options.provider,models:async()=>{note('models');return {synthetic:{id:'synthetic',name:'Synthetic',api:{npm:'@ai-sdk/openai-compatible'}}};}},
      });
    ''');
    final runtime = await PluginRuntime.start(
      executable: Platform.environment['LOONGPASS_BUN'] ?? 'bun',
      hostPath:
          Platform.environment['LOONGPASS_TEST_HOST'] ??
          File('runtime/vendor/magpie/host.js').absolute.path,
      launcherPath: File('runtime/launcher.mjs').absolute.path,
      directory: directory.path,
      plugins: [
        {
          'spec': 'identity-fixture',
          'target': fixture.path,
          'options': {'provider': provider},
        },
      ],
    );
    final store = MemoryAccountStore(directory.path);
    if (facts != null)
      store.data = {
        'version': 1,
        'accounts': {'$provider#synthetic': facts},
      };
    final accounts = PluginAccounts(
      runtime: runtime,
      directory: directory.path,
      store: store,
      enabledProviders: {provider},
    );
    final harness = _IdentityHarness(
      directory,
      runtime,
      store,
      accounts,
      provider,
      {
        'type': 'oauth',
        'uid': 'official',
        'accountId': 'Official',
        'access': 'fake',
        'refresh': '',
        'expires': 0,
        ...auth,
      },
    );
    await harness.replace({});
    if (start) await accounts.start();
    return harness;
  }
}

void _identityTests() {
  final opened = <_IdentityHarness>[];
  Future<_IdentityHarness> open({
    String provider = 'fixture',
    Map<String, dynamic> auth = const {},
    Map<String, dynamic>? facts,
    bool start = true,
  }) async {
    final h = await _IdentityHarness.open(
      provider: provider,
      auth: auth,
      facts: facts,
      start: start,
    );
    opened.add(h);
    return h;
  }

  tearDown(() async {
    for (final h in opened) {
      await h.close();
    }
    opened.clear();
  });
  Map<String, dynamic> row({
    String provider = 'fixture',
    String uid = 'official',
    String realm = '',
  }) => {
    'provider': provider,
    'uid': uid,
    'realm': realm,
    'registrationId': 'original-registration',
    'automatic': true,
  };

  for (final failure in ['reply', 'transport']) {
    test(
      'failed $failure usage read preserves the last verified quantities and time',
      () async {
        final h = await open();
        final before = h.accounts.accounts.single;
        await h.control(
          failure == 'reply'
              ? {
                  'usageResult': {
                    'error': 'private-provider-detail',
                    'signIn': 'kept',
                  },
                }
              : {'usageThrows': true},
        );
        await h.accounts.refresh();
        final failed = h.accounts.accounts.single;
        expect(failed.error, 'usage_unavailable');
        expect(failed.active, true);
        expect(failed.models, before.models);
        expect(failed.queriedAt, before.queriedAt);
        expect(
          (failed.usage!['windows'] as List).single,
          containsPair('amount', 1.25),
        );
        expect(
          (failed.usage!['windows'] as List).single,
          containsPair('limit', 100.125),
        );
        expect(
          (failed.usage!['windows'] as List).single,
          containsPair('unit', 'credits'),
        );
        expect(failed.usage!['error'], isNotEmpty);
        expect(jsonEncode(failed.usage), isNot(contains('private-')));
        expect(jsonEncode(h.store.data), isNot(contains('private-')));

        await h.control({});
        await h.accounts.refresh();
        final recovered = h.accounts.accounts.single;
        expect(recovered.error, isNull);
        expect(recovered.usage!['error'], '');
        expect(recovered.queriedAt!.isAfter(before.queriedAt!), true);
      },
    );
  }

  test('model loader failure does not suppress an independent official quota read', () async {
    final h = await open(start: false);
    await h.control({'loadThrows': true});
    await h.accounts.start();
    final account = h.accounts.accounts.single;
    expect((account.usage!['windows'] as List).single, containsPair('amount', 1.25));
    expect(account.error, 'catalog_unavailable');
    expect(account.queriedAt, isNotNull);
    expect(account.active, true);
    expect(account.models, isEmpty);
  });

  test('expired native usage authorization is actionable without fabricating a successful snapshot', () async {
    final h = await open(start: false);
    await h.control({
      'usageResult': {'error': 'expired-private-detail', 'signIn': 'expired'},
    });
    await h.accounts.start();
    final account = h.accounts.accounts.single;
    expect(account.error, 'authorization_required');
    expect(account.queriedAt, isNull);
    expect(account.usage!['signIn'], 'expired');
    expect(account.models, isNotEmpty);
    expect(account.active, true);
    await h.control({'usageThrows': true});
    await h.accounts.refresh();
    expect(h.accounts.accounts.single.usage!['signIn'], 'expired');
  });

  for (final mismatch in ['provider', 'uid', 'realm']) {
    test(
      'native $mismatch mismatch is quarantined before hooks and never rewrites credentials',
      () async {
        final facts = row()..[mismatch] = 'different';
        final h = await open(facts: facts, auth: {'expires': 1}, start: false);
        final before = await h.saved();
        await h.accounts.start();
        final account = h.accounts.accounts.single;
        expect(account.active, false);
        expect(account.facts['quarantine'], isNotNull);
        expect(account.models, isEmpty);
        expect(account.usage, isNull);
        expect(h.calls, isEmpty);
        expect(await h.saved(), before);
        await expectLater(
          h.accounts.currentCredential(h.key),
          throwsStateError,
        );
      },
    );
  }

  test(
    'quarantined first slot does not suppress a healthy sibling catalog after restart',
    () async {
      final h = await open(
        facts: row(uid: 'expected-blocked-uid'),
        auth: {'expires': 1, 'accountId': '138****1234'},
        start: false,
      );
      const goodKey = 'fixture#zzhealthy';
      await h.runtime.call('import', {
        'provider': 'fixture',
        'key': goodKey,
        'auth': {
          'type': 'oauth',
          'uid': 'healthy-uid',
          'accountId': '138****1234',
          'access': 'healthy-access',
          'refresh': '',
          'expires': 0,
        },
      });
      final before = (await h.accounts.credentials.account(h.key));
      await h.accounts.start();
      Future<void> check(PluginAccounts accounts) async {
        final bad = accounts.accounts.firstWhere((a) => a.key == h.key);
        final good = accounts.accounts.firstWhere((a) => a.key == goodKey);
        expect(bad.active, false);
        expect(bad.facts['quarantine'], isNotNull);
        expect(bad.models, isEmpty);
        expect(good.active, true);
        expect(good.uid, 'healthy-uid');
        expect(good.models.single['id'], 'synthetic');
        expect(good.usage, isNotNull);
        expect((await accounts.currentCredential(goodKey))['access'], 'healthy-access');
        await expectLater(accounts.currentCredential(h.key), throwsStateError);
        expect(
          (accounts.providers['fixture']!['accounts'] as List)
              .map((a) => a['key']),
          [goodKey],
        );
        expect(await accounts.credentials.account(h.key), before);
      }
      await check(h.accounts);
      // A fresh projection must rebuild the good slot without a cached catalog.
      final restarted = PluginAccounts(
        runtime: h.runtime,
        directory: h.directory.path,
        store: h.store,
        enabledProviders: {'fixture'},
      );
      try {
        await restarted.start();
        await check(restarted);
        expect(h.calls, isNot(contains('refresh')));
      } finally {
        await restarted.close();
      }
    },
  );

  test('native UID loss cannot activate an OAuth account', () async {
    final h = await open(auth: {'uid': ''});
    expect(h.accounts.accounts.single.active, false);
    expect(h.accounts.accounts.single.facts['quarantine'], isNotNull);
    expect(h.calls, isEmpty);
  });

  test(
    'provider-implied realms keep migrated CN and global identities usable',
    () async {
      for (final entry in {
        'minimax-code': 'cn',
        'minimax-code-global': 'global',
        'qoder-cn': 'cn',
        'qoder': 'global',
        'trae-cn': 'cn',
        'loomy': 'cn',
      }.entries) {
        final h = await open(
          provider: entry.key,
          facts: row(provider: entry.key, realm: entry.value),
        );
        expect(h.accounts.accounts.single.active, true, reason: entry.key);
        expect(h.accounts.accounts.single.realm, entry.value);
        expect((await h.accounts.currentCredential(h.key))['uid'], 'official');
      }
    },
  );

  test('dynamic native scopes remain distinct and missing WorkBuddy scope is unavailable', () async {
    for (final auth in [
      {'vpc': 'tenant-a'},
      {'dedicated': 'tenant.example.invalid'},
      {'enterpriseHost': 'enterprise.example.invalid'},
    ]) {
      final h = await open(provider: 'qoder-cn', auth: auth);
      expect(
        h.accounts.accounts.single.realm,
        '${auth.keys.single}:${auth.values.single}',
      );
      await h.replace({auth.keys.single: 'different'});
      await h.accounts.refresh();
      expect(h.accounts.accounts.single.active, false);
    }
    final h = await open(provider: 'workbuddy');
    expect(h.accounts.accounts.single.active, false);
  });

  test(
    'editing persisted identity immediately hides cached catalog and usage',
    () async {
      final h = await open();
      expect(h.accounts.accounts.single.models, isNotEmpty);
      expect(h.accounts.accounts.single.usage, isNotNull);
      await h.accounts.edit(
        (data) => data['accounts'][h.key]['realm'] = 'other',
      );
      expect(h.accounts.accounts.single.active, false);
      expect(h.accounts.accounts.single.models, isEmpty);
      expect(h.accounts.accounts.single.usage, isNull);
    },
  );

  test(
    'lost removal acknowledgement publishes the durable revoked lifetime',
    () async {
      final h = await open();
      var removedObserved = false;
      h.accounts.addListener(() {
        removedObserved = h.accounts.accounts.isEmpty;
      });
      h.store.afterWrite = () async => throw StateError('Lost acknowledgement');
      await expectLater(h.accounts.remove(h.key), throwsStateError);
      expect(h.store.data['accounts'][h.key]['removed'], true);
      expect(h.accounts.accounts, isEmpty);
      expect(removedObserved, true);
      await expectLater(h.accounts.currentCredential(h.key), throwsStateError);
      h.store.afterWrite = null;
    },
  );

  test(
    'lost automatic opt-out acknowledgement publishes durable scheduling facts',
    () async {
      final h = await open();
      var automatic = true;
      h.accounts.addListener(() {
        automatic = h.accounts.accounts.single.automatic;
      });
      h.store.afterWrite = () async => throw StateError('Lost acknowledgement');
      await expectLater(
        h.accounts.setAutomatic(h.key, false),
        throwsStateError,
      );
      expect(h.store.data['accounts'][h.key]['automatic'], false);
      expect(h.accounts.accounts.single.automatic, false);
      expect(automatic, false);
      h.store.afterWrite = null;
    },
  );

  test(
    'native authorization source is projected only for a verified identity',
    () async {
      final h = await open(auth: {'source': 'desktop'});
      expect(h.accounts.accounts.single.source, 'desktop');
      expect(h.store.data['accounts'][h.key].containsKey('source'), false);
      await h.accounts.edit(
        (data) => data['accounts'][h.key]['uid'] = 'different',
      );
      expect(h.accounts.accounts.single.source, isNull);
    },
  );

  test('currentCredential verifies live identity before renewal and after native rotation', () async {
    final h = await open();
    await h.replace({'uid': 'different', 'expires': 1});
    await h.clearCalls();
    final before = await h.saved();
    await expectLater(h.accounts.currentCredential(h.key), throwsStateError);
    expect(h.calls, isEmpty);
    expect(await h.saved(), before);
    expect(h.accounts.accounts.single.active, false);

    final rotated = await open();
    await rotated.control({
      'refresh': {'uid': 'different'},
    });
    await rotated.replace({'expires': 1});
    await expectLater(
      rotated.accounts.currentCredential(rotated.key),
      throwsStateError,
    );
    expect(rotated.accounts.accounts.single.active, false);
    expect(rotated.accounts.accounts.single.facts['uid'], 'official');
  });

  for (final stage in ['load', 'usage']) {
    test(
      'late native identity change during $stage discards the projection',
      () async {
        final h = await open();
        await h.control({
          stage: {'uid': 'different'},
        });
        // Native loaders run once per sign-in; use the host's own invalidation
        // so this refresh exercises a loader that really changes the identity.
        await h.runtime.call('reload', {
          'provider': h.provider,
          'account': h.key,
        });
        await h.clearCalls();
        await h.accounts.refresh();
        final account = h.accounts.accounts.single;
        expect(account.active, false);
        expect(account.models, isEmpty);
        expect(account.usage, isNull);
        if (stage == 'load') expect(h.calls, isNot(contains('usage')));
      },
    );
  }

  test(
    'reauthorization cannot change realm or UID of an existing saved identity',
    () async {
      final h = await open(auth: {'domain': 'original'});
      final registration = h.accounts.accounts.single.registrationId;
      await h.replace({'domain': 'other'});
      final before = await h.saved();
      await expectLater(h.accounts.authorizationSaved(h.key), throwsStateError);
      expect(h.accounts.accounts.single.realm, 'original');
      expect(h.accounts.accounts.single.registrationId, registration);
      expect(h.accounts.accounts.single.active, false);
      expect(await h.saved(), before);
      await h.replace({'domain': 'original', 'name': 'New label'});
      await h.accounts.authorizationSaved(h.key);
      expect(h.accounts.accounts.single.active, true);
      expect(h.accounts.accounts.single.registrationId, isNot(registration));
      expect(h.accounts.accounts.single.label, 'New label');
    },
  );

  for (final changed in ['removed', 'registrationId']) {
    test('target authorization cannot restore a changed $changed', () async {
      final h = await open();
      final registration = h.accounts.accounts.single.registrationId;
      await h.accounts.edit((data) {
        data['accounts'][h.key][changed] = changed == 'removed' ? true : 'new';
      });
      final authBefore = await h.saved();
      final factsBefore = jsonEncode(h.store.data);
      await expectLater(
        h.accounts.authorizationSaved(
          h.key,
          expectedRegistrationId: registration,
        ),
        throwsStateError,
      );
      expect(jsonEncode(h.store.data), factsBefore);
      expect(await h.saved(), authBefore);
    });
  }

  test(
    'verifyCredential admits scoped API identity without any native refresh',
    () async {
      final h = await open(
        auth: {
          'type': 'api',
          'uid': null,
          'accountId': 'api:scoped-first',
          'key': 'synthetic-key',
        },
      );
      expect(h.accounts.accounts.single.active, true);
      expect(h.accounts.accounts.single.uid, '');
      expect(h.accounts.accounts.single.automatic, false);
      expect(h.store.data['accounts'][h.key]['accountId'], 'api:scoped-first');
      await h.clearCalls();
      await h.accounts.verifyCredential(h.key);
      expect(h.calls, isEmpty);
      await h.replace({'accountId': 'api:scoped-second'});
      final before = await h.saved();
      await expectLater(h.accounts.verifyCredential(h.key), throwsStateError);
      expect(h.accounts.accounts.single.active, false);
      expect(h.accounts.accounts.single.models, isEmpty);
      expect(h.accounts.accounts.single.usage, isNull);
      expect(h.calls, isEmpty);
      expect(await h.saved(), before);
      expect(h.store.data['accounts'][h.key]['accountId'], 'api:scoped-first');
    },
  );

  test(
    'API credentials without a scoped native identity are quarantined',
    () async {
      final h = await open(
        auth: {
          'type': 'api',
          'uid': null,
          'accountId': null,
          'key': 'synthetic',
        },
      );
      expect(h.accounts.accounts.single.active, false);
      expect(h.calls, isEmpty);
      await expectLater(h.accounts.verifyCredential(h.key), throwsStateError);
    },
  );

  test('API sign-in preserves native email input and isolates equal keys by prompt scope', () async {
    final h = await open();
    Future<String> login(String site, {int method = 0}) =>
        PluginSignIn(h.runtime, onSaved: h.accounts.authorizationSaved).apiKey(
          'fixture',
          method,
          {'email': 'native@example.invalid', 'site': site},
          'same-synthetic-secret',
        );
    final first = await login('one');
    final repeat = await login('one');
    final second = await login('two');
    expect(repeat, first);
    expect(second, isNot(first));
    final one = await h.accounts.credentials.account(first),
        two = await h.accounts.credentials.account(second);
    expect(one['metadata'], {'email': 'native@example.invalid', 'site': 'one'});
    expect(two['metadata'], {'email': 'native@example.invalid', 'site': 'two'});
    expect(one['accountId'], startsWith('api:'));
    expect(two['accountId'], isNot(one['accountId']));
    expect(h.store.data['accounts'][first]['accountId'], one['accountId']);
    expect(
      h.accounts.accounts.firstWhere((a) => a.key == first).automatic,
      false,
    );
    await expectLater(h.accounts.currentCredential(first), throwsStateError);
    final authorized = await login('three', method: 1);
    expect(
      jsonDecode(await File('${h.directory.path}/inputs.json').readAsString()),
      {'email': 'native@example.invalid', 'site': 'three'},
    );
    expect((await h.accounts.credentials.account(authorized))['metadata'], {
      'fromPlugin': 'preserved',
    });
  });

  test(
    'API authorization returning OAuth keeps the native official identity',
    () async {
      final h = await open();
      final key = await PluginSignIn(
        h.runtime,
        onSaved: h.accounts.authorizationSaved,
      ).apiKey('fixture', 2, {'email': 'native@example.invalid'}, 'synthetic');
      final auth = await h.accounts.credentials.account(key);
      expect(auth['type'], 'oauth');
      expect(auth['uid'], 'official-oauth');
      expect(auth['accountId'], 'official-account');
    },
  );
}
