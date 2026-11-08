import 'account_document_store.dart';

class LegacyAccountSources {
  LegacyAccountSources({
    required this.documents,
    required this.readVault,
    required this.retireVault,
    required this.readWorkBuddyClaims,
  });
  final Map<String, AccountDocumentStore> documents;
  final Future<Map<String, dynamic>> Function() readVault;
  final Future<void> Function(Map<String, dynamic>) retireVault;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)
  readWorkBuddyClaims;
  Future<Map<String, dynamic>> read() async {
    final revisions = <String, int>{};
    final sources = <String, dynamic>{'_revisions': revisions};
    for (final e in documents.entries) {
      final snapshot = await e.value.read();
      sources[e.key] = snapshot.data;
      revisions[e.key] = snapshot.revision;
    }
    sources['WorkBuddy'] = await readVault();
    sources['WorkBuddyClaims'] = await readWorkBuddyClaims(
      sources['WorkBuddy'],
    );
    return sources;
  }

  Future<void> retire(Map<String, dynamic> frozen) async {
    for (final e in documents.entries) {
      // ModelService contains local caller grants, never supplier credentials.
      if (e.key == 'ModelService') continue;
      final snapshot = await e.value.read();
      if (snapshot.data.isEmpty ||
          (snapshot.data['accounts'] is Map &&
              (snapshot.data['accounts'] as Map).isEmpty))
        continue;
      if (snapshot.revision != frozen['_revisions'][e.key]) {
        throw StateError('Legacy account owner changed during migration');
      }
      // The verified backup preserves the originals; old binaries no longer
      // have credentials they could rotate after ownership moves to the host.
      await e.value.write(snapshot.revision, {
        ...snapshot.data,
        'accounts': <String, dynamic>{},
      });
    }
    await retireVault(Map<String, dynamic>.from(frozen['WorkBuddy'] as Map));
  }
}
