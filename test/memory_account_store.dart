import 'dart:convert';
import '../lib/account_document_store.dart';

/// Synthetic store only. Native permissions/fsync/locks have separate checks.
class MemoryAccountStore implements AccountDocumentStore {
  @override
  final String identity;
  MemoryAccountStore(this.identity);
  int revision = 0;
  Map<String, dynamic> data = {};
  Future<void> Function()? beforeWrite, afterWrite;
  @override
  Future<AccountDocument> read() async => AccountDocument(
    revision,
    jsonDecode(jsonEncode(data)) as Map<String, dynamic>,
  );
  @override
  Future<void> write(int expectedRevision, Map<String, dynamic> next) async {
    await beforeWrite?.call();
    if (revision != expectedRevision) throw StateError('stale revision');
    data = jsonDecode(jsonEncode(next)) as Map<String, dynamic>;
    revision++;
    await afterWrite?.call();
  }
}
