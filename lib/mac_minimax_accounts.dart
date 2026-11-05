import 'dart:async';
import 'mac_account_document_store.dart';
import 'minimax_accounts.dart';

/// Each region has a separate native-owned atomic document.
Future<MiniMaxAccounts> openMacMiniMaxAccounts({
  required String region,
  FutureOr<void> Function()? onAutomaticFinished,
}) async {
  return MiniMaxAccounts(
    store: MiniMaxAccountStore(MacAccountDocumentStore('MiniMax-$region')),
    onAutomaticFinished: onAutomaticFinished,
  );
}
