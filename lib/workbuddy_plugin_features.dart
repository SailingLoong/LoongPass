import 'plugin_accounts.dart';
import 'workbuddy_api.dart';
import 'workbuddy_desktop_session.dart';

/// WorkBuddy-only desktop behavior. Native Magpie remains the grant owner.
class WorkBuddyPluginFeatures {
  WorkBuddyPluginFeatures(this.accounts, {WorkBuddyExchange? exchange})
    : exchange = exchange ?? WorkBuddyHttps();
  final PluginAccounts accounts;
  final WorkBuddyExchange exchange;

  Future<String> activate(
    String key, {
    required Future<String> Function(WorkBuddyDesktopSession) apply,
  }) async {
    final selected = accounts.accounts.singleWhere((a) => a.key == key);
    bool current() => accounts.accounts.any(
      (a) =>
          a.key == key &&
          a.active &&
          a.registrationId == selected.registrationId,
    );
    final grant = await accounts.currentCredential(key);
    final uid = grant['uid'];
    if (selected.provider != 'workbuddy' || uid != selected.uid || !current()) {
      throw const WorkBuddyApiFailure(
        'ExpiredAuthorization',
        mayHaveBeenSent: false,
      );
    }
    final expires = grant['expires'];
    final account = WorkBuddyAccount(
      grant['domain'] as String,
      uid as String,
      grant['access'] as String,
      expiresAt: expires is num && expires > 0
          ? DateTime.fromMillisecondsSinceEpoch(expires.toInt())
          : null,
    );
    final api = WorkBuddyApi(exchange, isCurrent: current);
    final session = await api.desktopSession(account, gate: current);
    final latest = await accounts.credentials.account(key);
    if (!current() ||
        latest['uid'] != uid ||
        latest['access'] != grant['access']) {
      throw const WorkBuddyApiFailure(
        'ExpiredAuthorization',
        mayHaveBeenSent: false,
      );
    }
    return apply(session);
  }
}
