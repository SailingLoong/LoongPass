# WorkBuddy integration

The existing WorkBuddy navigation page now connects a session-only multi-account roster of independent in-memory owners, the reviewed claim core, mature complete-balance requests/normalization, and the current macOS MethodChannel for browser opening and private-directory syncing. Production controls remain behind the independent WorkBuddy gate, separate from Qoder/MiniMax validation. The default production memory factory and Flutter factory/opener reject before side effects, and the actual HTTPS sender rejects before allocating a client. The native handler separately rejects WorkBuddy methods before browser or journal access. Both Dart and native gates are false; future enablement requires reviewing both. Explicit synthetic exchange/owner injection remains available to isolated tests, with no bypass on the real HTTPS sender. See `README.md` for the current verification receipt.

## Multiple accounts and authorization sessions

The roster is lazy. Each explicit authorization creates a fresh existing WorkBuddyAccountFlow with its own state, deadline, credential generation and network gate. Multiple pending sessions can be polled or cancelled independently. Only profile-verified domain+UID identities enter the account list. Duplicate identity authorization preserves the original owner and receipt state; no implicit replacement occurs. Selection is local, and every query/claim pins its session ID so late results stay on their originating account.

Manual and explicitly opted-in session claims are serialized per roster with no automatic queue or retry. Other roster/process contention still uses the existing journal locking/CAS and fails closed. Removing a memory account or closing the page retires its gates but never deletes durable attempts. Relaunch starts without credentials and requires explicit reauthorization; unknown receipts remain blocked, settled same-day records do not post again. This is safe preservation/rebinding, not automatic login restoration or guaranteed resolution of unknown outcomes.

A reused, busy, pending or already-authenticated factory owner is rejected without closing its original session. The UI uses stable callbacks; use a new widget key to replace them. Session IDs and account metadata are not credential inputs.

## Credentials and requests

Official authorization establishes the profile-verified CN personal account. Credentials remain private in the owner's memory. No existing app credentials are discovered, replaced, saved or imported. A new memory owner has its own random generation and retires all send gates on close. The same private account supplies status, balance and claim headers.

The balance reader uses the pinned summary/paid/free POST endpoints and exact package lists. It proves complete single pages, deduplicates resource IDs, applies UTC+8 expiration, and returns null for partial/uncertain totals. It does not invent pagination or use a partial sum. Historical web Origin/Referer/X-Client-Platform assertions are intentionally omitted; actual provider acceptance is unverified. The three responses are not an atomic server snapshot.

## Local claim state

The production factory uses `WorkBuddyAttemptJournal` in the native-prepared `LoongPass/WorkBuddy` directory. This is a small record adapter using the existing Qoder append-only journal mechanisms: one owning isolate, POSIX process file lock, append/flush/readback, then native directory fsync. It stores only domain, UID, credential generation, China day, baseline, receipt and settled result. It never stores an access token or provides a reset/delete operation.

An intent is acknowledged before the single claim request. Unknown results, incomplete writes and failed syncs cannot authorize another request; reopening or reauthorizing retains the unresolved record. This targets ordinary exceptions and process restarts. It does not claim protection against manual journal deletion, restoration of an old backup, malicious same-UID tampering or untested hardware power loss.

All claim requests still pass through `WorkBuddyClaimCore`; a receipt alone is not credited success. The UI keeps activity status, complete remaining balance and the attempt's credited outcome separate. One attempt per memory-owner lifetime is deliberate. Keep injected callbacks stable for a widget lifetime; use a new widget key when replacing a credential owner.

## Still not implemented or verified

Session-only one-shot automation is described in WORKBUDDY-AUTOMATIC.md. No native WorkBuddy desktop-credential switching, persisted credentials, restart/daily unattended automation, bulk check-in or manual unknown-attempt resolution is added. Mac release compilation succeeds; Flutter rendering/widget/engine acceptance and live-account compatibility are not established by the standalone synthetic checks. Multiple real website grants, identity selection, lifecycle expiry and service-side cancellation/revocation still require account-specific validation. The default native-validation switch remains false. Cancelling an in-memory login does not revoke a grant the user may already have accepted on the service's website.
