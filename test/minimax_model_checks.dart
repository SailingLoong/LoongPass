import 'dart:convert';
import '../lib/minimax_accounts.dart';
import '../lib/minimax_model_provider.dart';
import '../lib/model_http.dart';
import '../lib/model_provider.dart';
import 'memory_account_store.dart';
import 'minimax_accounts_checks.dart' show FakeHttp;
import 'synthetic_fixture.dart' as fixture;

void check(bool ok, String why) {
  if (!ok) throw StateError(why);
}

class Wire implements ModelTransport {
  final calls = <(Uri, Map<String, String>, Object?)>[];
  Object catalog = {
    'providers': [
      {
        'providerId': 'minimax',
        'config': {
          'models': {
            'vendor-model': {
              'name': 'Official',
              'limit': {'context': 204800, 'output': 8192},
            },
          },
        },
      },
    ],
  };
  @override
  Future<void> exchange(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const {},
    Object? body,
    required bool Function() isCurrent,
    Future<void>? cancelled,
    required Future<void> Function(ModelReply) consume,
  }) async {
    check(isCurrent(), 'lease absent');
    calls.add((uri, headers, body));
    await consume(
      ModelReply(
        200,
        'application/json',
        Stream.value(
          utf8.encode(
            jsonEncode(
              method == 'GET'
                  ? catalog
                  : {
                      'content': [
                        {'type': 'text', 'text': 'ok'},
                      ],
                    },
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> main() async {
  final owner = MiniMaxAccounts(
    store: MiniMaxAccountStore(MemoryAccountStore('minimax-model')),
    http: FakeHttp(),
    nowMs: () => 100000,
  );
  final credential = MiniMaxCredential.parse(
    fixture.bytes(),
    sourcePath: fixture.path(fixture.MiniMaxRegion.cn),
    region: 'cn',
    nowMs: 100000,
  );
  final account = await owner.save(
    await owner.verifySource(() => Future.value(credential), confirmed: true),
    confirmed: true,
  );
  final wire = Wire();
  final source = MiniMaxModelProvider(owner, 'cn', transport: wire);
  try {
    final catalog = await source.discoverModels(account.id);
    check(
      catalog.models.single.id == 'vendor-model' &&
          catalog.models.single.contextWindow == 204800 &&
          catalog.models.single.outputLimit == 8192,
      'live absolute limits',
    );
    check(
      (await source.accounts()).single.registrationId == catalog.registrationId,
      'registration mismatch',
    );
    check(
      wire.calls.single.$1.toString() ==
          'https://agent.minimax.cn/mavis/api/v1/models?region=cn&buildEnv=prod',
      'discovery endpoint',
    );
    final body = <String, dynamic>{
      'model': 'vendor-model',
      'messages': [
        {'role': 'user', 'content': '你好'},
      ],
      'tools': [
        {
          'name': 'echo',
          'input_schema': {'type': 'object'},
        },
      ],
    };
    await source.dispatch(
      account.id,
      catalog.registrationId,
      ModelProtocol.messages,
      body,
      (r) async {
        await r.body.drain<void>();
      },
      isCurrent: () => true,
      cancelled: Future<void>.value(),
    );
    check(identical(wire.calls.last.$3, body), 'native tool/body rewritten');
    check(
      wire.calls.last.$1.path == '/mavis/api/v1/llm/v1/messages',
      'inference route',
    );
    check(
      wire.calls.last.$2['Authorization'] == 'Bearer synthetic-access',
      'wrong owner token',
    );
    wire.catalog = {'providers': []};
    var failed = false;
    try {
      await source.discoverModels(account.id);
    } catch (_) {
      failed = true;
    }
    check(failed, 'guessed models on empty official catalog');
    print(
      'PASS MiniMax live catalog, exact limits, native tools and owner lease',
    );
  } finally {
    owner.dispose();
  }
}
