# WorkBuddy session automation and restart-access assessment

## Implemented in this candidate

Each admitted memory account starts with automation off. The first explicit opt-in registers one shared startup check after 30 seconds and a periodic check every 15 minutes; additional accounts join the next shared check, reusing the existing MiniMax in-process cadence. Status is checked before invoking the existing claim flow/core/journal. Ineligible or uncertain status remains query-only; an attempted, already-claimed or authentication-rejected account is disarmed. The existing one-attempt-per-authorization-lifetime guard is unchanged. This is one session attempt, not long-term daily automation.

Policy revision and timer epoch gates prevent stale work after off/on, removal, close or timer cancellation. Automatic status and claim operations carry admission through roster ownership, core/journal checks and the actual HTTP send boundary. Already dispatched requests cannot be recalled. Possibly committed intents remain unknown rather than being cleared/replayed. Manual refresh/claim does not depend on automatic opt-in. Claims remain serialized without hidden queueing.

The panel owns the scheduler and closes it before closing memory accounts. No credential, automatic preference, account catalogue, login item, launch daemon or background service is created. Restart requires reauthorization and a new opt-in. No refresh-token request or persistence implementation was added. Both WorkBuddy production gates remain false.

## Does restart automation require a refresh token?

Not necessarily for a short interval: a securely persisted, still-valid access token may be sufficient until expiry. But resuming without any user reauthorization requires some recoverable authentication material. Long-lived unattended renewal needs a supported refresh token or equivalent persistent grant, with verified expiry/rotation/revocation rules. The noncredential intent journal alone cannot restore authentication.

The current WorkBuddy API retains only the access token and known access expiry in memory. It does not retain or implement refresh-token renewal. Official 5.9.3 static evidence indicates a refresh mechanism, but its real server behavior and rotation/revocation remain unaccepted. Do not guess a refresh token, derive one from other clients, or automatically retry an uncertain rotation.

## Proposed future storage, NOT created or enabled

Use the existing macOS SecItem pattern with a separate generic-password service `com.sailingloong.loongpass.workbuddy`, not the MiniMax/Qoder services. The account identifier should be an opaque digest of the verified domain+UID. The versioned Keychain value would hold only necessary access/refresh credentials (refresh token only when actually issued and verified), access/refresh expiry, the immutable endpoint/domain/UID binding, credential generation and explicit automation policy/revision. This can keep restoration metadata with the same protected item rather than introduce another account database.

The target is a logical OS Keychain item accessed through SecItem APIs; never directly write a keychain-db file. Reuse noninteractive reads and disabled synchronization. Locked or denied Keychain access must stop automation, not unlock the machine or alter ACL/security settings. No such WorkBuddy item was created by this task.

The existing noncredential record remains `~/Library/Application Support/LoongPass/WorkBuddy/workbuddy-intents.jsonl`, prepared by the current native owner. It contains domain, UID, generation/day, baseline and receipt/settlement only. Do not add token or policy fields to its strict schema. Logs, exports and ordinary JSON files must not receive credentials.

## Recovery and revocation boundaries

- Local off closes automatic admission immediately, cancels timer generations and preserves receipts. It does not revoke a website grant or undo a sent claim.
- Future local removal should delete only that account's LoongPass Keychain item and disable its policy; account data in official clients stays untouched. Pending/unknown receipts must remain, including after reauthorization.
- Provider-side revocation needs a separately verified supported mechanism. Local deletion is not proof of server revocation; no revoke request is implemented here.
- Refresh rotation requires validated account/domain/expiry, staged credential-generation commit and failure/readback handling. A timed-out refresh may have consumed/rotated the old token; do not promise rollback to the old refresh token or retry it automatically. Uncertain state must stop and require reauthorization.
- Saving reusable credentials/refresh material and enabling restart access require concrete action-time approval. Real claim acceptance separately changes account state and consumes any relevant opportunity. This phase did neither.

## Minimum additional steps for real restart/daily operation

1. Verify independent multi-account authorization and authenticated profile/status/balance/claim contracts with specifically approved real accounts. Public/synthetic responses cannot establish this.
2. Only after approval to establish persistent access, implement Keychain save/readback/removal and a restore path that revalidates profile/domain/UID and expiry. A stored UID is not authentication proof. Reuse the current receipt key/generation rules.
3. Validate optional refresh and rotation with partial-write, timeout and lost-ack handling; stop if renewal is unavailable or uncertain. Credential persistence alone does not provide safe renewal.
4. The current flow intentionally allows one attempt per authorization lifetime. Long-term daily operation needs a separately reviewed transition for a settled previous period; never reset an unknown intent or release a POST merely because the local date changed.
5. Verify real Flutter/engine timers, journal syncing and quit/restart. An application restart still needs app launch; machine-reboot unattended launch would require a separately approved login/background mechanism. Locked Keychain must remain a stop condition.

## Remaining acceptance

Real two-account authorization, status/balance/receipt contracts, rate limits and renewal/revocation have not been verified. Fake timers exercise callbacks but do not validate wall-clock duration, OS sleep/resume or Flutter rendering. Existing native journal behavior is unchanged; full multi-account engine/fsync acceptance remains separate. This candidate must not be described as completed unattended multi-account sign-in.

Other platforms are not changed: Qoder China is manual; Qoder international still lacks its production authentication gateway; MiniMax already has persisted own-Keychain credentials and in-process opt-ins but requires account loading and stops at expiry, with no new renewal added here; ZCode still lacks an independent LoongPass authorization source for real activities.
