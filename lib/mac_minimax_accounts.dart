import 'dart:async';
import 'dart:io';
import 'mac_minimax_keychain.dart';
import 'minimax_accounts.dart';

/// Call after the host wires MiniMaxKeychain.handle into its existing channel.
/// Does not read an external account, persist a credential, or enable automation.
Future<MiniMaxAccounts> openMacMiniMaxAccounts({FutureOr<void> Function()? onAutomaticFinished}) async {
  final keychain = MacMiniMaxKeychain();
  final root = Directory(await keychain.prepareJournal());
  return MiniMaxAccounts(
    store: MiniMaxMetadataStore(root, syncDirectory: keychain.syncJournal),
    onAutomaticFinished: onAutomaticFinished,
    readSecret: keychain.read,
    writeSecret: keychain.write,
    deleteSecret: keychain.delete,
  );
}
