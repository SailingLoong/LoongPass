import 'dart:async';
import 'native_account_document_store.dart';
import 'minimax_accounts.dart';

/// Each region has a separate native-owned atomic document.
Future<MiniMaxAccounts> openNativeMiniMaxAccounts({
  required String region,
  FutureOr<void> Function()? onAutomaticFinished,
}) async {
  return MiniMaxAccounts(
    store: MiniMaxAccountStore(NativeAccountDocumentStore('MiniMax-$region')),
    onAutomaticFinished: onAutomaticFinished,
  );
}
