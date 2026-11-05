/// The native store owns private permissions, the lifetime writer lock and
/// atomic replacement. Each platform owns its document schema and operations.
abstract interface class AccountDocumentStore {
  String get identity;
  Future<AccountDocument> read();
  Future<void> write(int expectedRevision, Map<String, dynamic> data);
}

class AccountDocument {
  final int revision;
  final Map<String, dynamic> data;
  AccountDocument(this.revision, this.data);
  @override
  String toString() => 'AccountDocument(redacted)';
}
