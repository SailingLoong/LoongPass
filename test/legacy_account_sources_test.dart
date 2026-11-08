import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/account_document_store.dart';
import '../lib/legacy_account_sources.dart';

void main() {
  test(
    'retirement removes old grants once and retains their receipt history',
    () async {
      final store = _Store({
        'version': 1,
        'accounts': {
          'a': {'token': 'legacy'},
        },
        'claims': {
          'receipt': {'state': 'unknown'},
        },
      });
      final source = LegacyAccountSources(
        documents: {'Qoder-cn': store},
        readVault: () async => {},
        retireVault: (_) async {},
        readWorkBuddyClaims: (_) async => {},
      );
      final frozen = await source.read();
      await source.retire(frozen);
      await source.retire(frozen);
      final result = (await store.read()).data;
      expect(result['accounts'], isEmpty);
      expect(result['claims'], {
        'receipt': {'state': 'unknown'},
      });
      expect(frozen['Qoder-cn']['accounts']['a']['token'], 'legacy');
      expect(store.revision, 1);
    },
  );
  test('a changed legacy owner cannot be silently retired from an earlier snapshot', () async {
    final store = _Store({
      'accounts': {
        'a': {'token': 'old'},
      },
    });
    final source = LegacyAccountSources(
      documents: {'Qoder-cn': store},
      readVault: () async => {},
      retireVault: (_) async {},
      readWorkBuddyClaims: (_) async => {},
    );
    final frozen = await source.read();
    await store.write(0, {
      'accounts': {
        'a': {'token': 'new'},
      },
    });
    await expectLater(source.retire(frozen), throwsA(isA<StateError>()));
    expect((await store.read()).data['accounts']['a']['token'], 'new');
  });
}

class _Store implements AccountDocumentStore {
  _Store(this.data);
  Map<String, dynamic> data;
  int revision = 0;
  @override
  String get identity => 'fixture';
  @override
  Future<AccountDocument> read() async =>
      AccountDocument(revision, jsonDecode(jsonEncode(data)));
  @override
  Future<void> write(int expectedRevision, Map<String, dynamic> value) async {
    if (expectedRevision != revision) throw StateError('changed');
    revision++;
    data = jsonDecode(jsonEncode(value));
  }
}
