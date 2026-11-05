Historical build 11 evidence; build 12 changes and current boundaries are in WORKBUDDY-RESTORE.md.

# Build 11: synthetic persistence preparation

This candidate adds WorkBuddyVaultStore, an injected Dart lifecycle coordinator,
Flutter transport wiring and a native dedicated-Keychain backend. No production
Keychain target is configured, both WorkBuddy gates remain false, and no UI
creates this store. It does not save or read real credentials.

Per opaque account key the versioned record holds domain, endpoint, UID,
access/optional refresh token, expiry and revision. Restoration requires an
injected identity verifier and dispatch admission, rechecks durable revision,
never restores automatic opt-in and never clears the claim-intent journal.
Local revocation immediately retires memory leases and replaces credential
material with a durable secret-free tombstone, including for an absent record.
A failed durable revoke is reported unresolved; memory stops but future-process
revocation cannot be promised until the tombstone is confirmed. This is not
server-side revocation, forensic erasure or a guarantee of memory zeroization.

Rotation is bookkeeping only: pending is persisted before a hypothetical refresh
send; uncertainty remains disabled after reconstruction. Completion requires the
same owner ticket, expected revision and unchanged identity bindings. No refresh
endpoint is implemented or called; no unknown rotation is retried. Closed and
revoked owners cannot dispatch restoration verification or return a new ticket.

Native operations are explicitly scoped to a newly created test Keychain. Legacy
Keychain query UI flags alone proved insufficient for locked reads; the backend
now reuses LoongPassKeychainLock, disables interaction only in this process for
the operation and restores the previous flag. It never unlocks a Keychain or
changes ACLs, search-list/default setters, shell or system security settings.
The fixture lifecycle may register/unregister its own dedicated Keychain;
search-list equality after cleanup is checked by the native probe.

Validation: 35 Dart lifecycle checks; 27 native dedicated-Keychain checks;
13 Dart -> JSON IPC -> FlutterMethodCall handler -> Keychain integration checks;
247 existing WorkBuddy synthetic checks (journal suite needs canonical task TMPDIR);
macOS universal release build 1.0.0 (11), strict deep codesign verification.
The IPC probe is not a Flutter-engine/UI channel test or a server acceptance test.
Ad-hoc signature only; no Developer ID, notarization, upload or publication.

Before real two-account use: implement and accept the actual profile-verification
adapter, account-key derivation, roster/flow restoration and retirement wiring,
production Keychain destination/ownership and cross-process exclusion. The current
native CAS is single host-process only. Verify supported refresh/expiry/revocation
contracts, recovery and journal reconciliation; do not infer them from this test.
Then separately approve the concrete persistent-access operation at action time,
with destination, credential types and local removal limits shown. The user must
authorize each account on the verified official page, never send secrets to chat.
Actual check-in requires its own action-time confirmation; uncertain outcomes
remain read-only reconciliation and must never cause repeat POSTs. No safe real
login page is offered by this candidate while production admission remains closed.
