# Build 12: minimal WorkBuddy add/save/restore wiring

Reference read-only: old LoongPort loongport-pr634 WorkBuddyAccounts.tsx,
lib/api/workbuddy.ts and src-tauri/src/workbuddy/authorization.rs. Reuse the
existing Add -> AuthState -> official page -> AuthToken -> strict Profile -> save
-> roster sequence. No inference authorization, models, proxy pool, old
SecretSession/vault/sync framework or native-client account import is added.
Old 10-minute authorization timeout is not copied; current official-contract
5-minute timeout, pending behavior and strict personal context remain unchanged.
Only the already pinned domestic WorkBuddy/CodeBuddy domains are supported.

The existing begin/poll implementation remains the only login flow. Explicit,
injected pollAndSave waits for verified UID/domain, derives an opaque per-account
key using the existing sourceSha256 helper, saves through the existing vault,
binds that saved record's lease, then admits into the existing roster. A second
add creates a separate identity. Duplicates preserve the existing owner. Unknown
expiry refuses persistence. No token getter, second login protocol or account DB.

Fresh roster restoration reads the same store and reuses the existing profile
GET contract with Bearer and X-Domain, no placeholder user-id header. Identity,
endpoint, token, refresh-token and expiry bindings are checked. Expired, revoked,
pending rotation, mismatched profile and cancelled owners are never admitted.
Every restored/saved API send performs a durable admission check and then the
existing synchronous lifecycle checks. Local roster revocation retires the flow
before awaiting its credential-free tombstone. Unknown claim-intent history is
preserved across generations and never reset by restoration.

A Security commit followed by readback failure is not assumed rolled back.
The coordinator blocks that key and attempts to tombstone only its exact initial
record. Failed readback/cleanup remains explicitly unresolved; no future-process
cleanup guarantee is made during a storage outage. A late successful save is
revoked when its action was cancelled. Automatic opt-in is never restored.

The native vault requires a lifetime owner.lock flock for its dedicated private
Keychain directory; that root must match the Keychain path. It checks canonical
root identity, ownership, mode, ACL absence/emptiness, lock inode/type/mode/link
count, and uses O_NOFOLLOW/O_CLOEXEC. Cooperating second processes are rejected;
normal exit and OS crash release are tested. The file is never unlinked while
owned. This is not protection against a hostile process under the same UID, nor
an atomic transaction with the remote server. Another independent Dart coordinator
revoking during HTTP setup does not guarantee immediate cancellation of that
already-admitted request. The supported roster revoke path closes its flow first.

Production remains closed: WorkBuddy UI/API and persistent-access gates false,
no default/login Keychain target, no real credentials or live account calls.
The public UI keeps its existing memory-login path; injected persistent wiring
is not activated for users. The initial two-account webpage acceptance can be
memory-only, without waiting for refresh/long-term access. No verified live URL
or real authorization opportunity was created or consumed in these checks.

Before the user can operate a real official page: action-time approval for the
specific real authorization/token receipt and profile requests, a narrow live
contract/URL validation, then acceptance of the gated login UI for two accounts.
No passwords/tokens in chat or official-client account operations are needed.
Persistent login additionally needs an approved production Keychain destination
and persistent credential scope/recovery review. Actual check-in needs its own
action-time confirmation. Refresh/revocation APIs remain unimplemented and
unverified; local tombstones do not claim website grant revocation.
