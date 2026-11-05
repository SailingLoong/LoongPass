import 'dart:convert';

/// A short-lived session for the official desktop client's existing storage
/// contract. The API owner verifies the complete profile before constructing it.
class WorkBuddyDesktopSession {
  final String _document;

  WorkBuddyDesktopSession({
    required Map<String, Object?> verifiedProfile,
    required String domain,
    required String accessToken,
    required DateTime? expiresAt,
  }) : _document = jsonEncode({
         'account': verifiedProfile,
         'auth': {
           'accessToken': accessToken,
           'domain': domain,
           if (expiresAt != null) 'expiresAt': expiresAt.millisecondsSinceEpoch,
         },
         'accounts': [verifiedProfile],
         'allAccounts': [verifiedProfile],
       });

  /// Kept out of account DTOs and diagnostics. Used only for the native call.
  Map<String, Object?> nativeMessage() =>
      jsonDecode(_document) as Map<String, Object?>;

  @override
  String toString() => 'WorkBuddyDesktopSession(redacted)';
}
