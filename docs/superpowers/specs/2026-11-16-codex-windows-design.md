# Codex official accounts on Windows

## Goal and scope

Add the existing Codex account experience to Windows and verify an actual official desktop account round trip. Preserve existing macOS accounts and behavior. Saving credentials, selecting a row, or reopening a process is insufficient evidence of a successful desktop switch.

The authorized scope includes official authorization, import of the current login, multiple saved identities, restart persistence, account removal, and explicit desktop activation. Account identity remains the official user plus workspace. Credentials and raw authentication responses remain inside native adapters.

## Approach

Use the existing Flutter view and method-channel contract with a Windows native adapter. Reuse the Windows private account-file owner for durable storage. Use the installed official Codex executable for effective configuration, browser authorization and renewal. Follow LoongPort's Windows lifecycle: discover the MSIX package and application identity at runtime; explicitly disclose forced termination; stop the selected official desktop process tree; observe termination; apply the selected login; open through its application identity after successful activation.

This is the recommended implementation choice: Windows already uses C++ bridges for private storage and authorization, while macOS uses Swift. A second service/runtime would duplicate application lifecycle management. Migrating the working macOS adapter into a new shared runtime would expand this platform addition into an unrelated storage migration. Shared synthetic fixtures will check the identity and local-preference contract on both native implementations.

The C++ code is necessary Windows SDK integration within the existing Flutter application. It does not introduce a separate service or a new UI stack.

## Ownership and boundaries

- A native account coordinator owns initialization, authorization, renewal, observations and mutations. Snapshot reads and Flutter polling consume its existing state.
- Reuse the private file owner and its ACL, lifetime lock and atomic persistence. Keep Codex's account document separate from other platform stores.
- Separate credential/settings projections, account persistence and activation transactions, official executable/stdio/process operations, and method-channel coordination.
- Only the official file credential store is supported. Respect effective login/workspace restrictions; unsupported stores do not cause configuration rewrites.
- Stop and reap each owned authorization process before reading its final credentials. Cancel and application shutdown stop owned work and remove temporary homes.
- Validate paths, ownership and file identity; refuse reparse points, linked authentication files, concurrent changes and unrelated CLI writers. Never terminate unrelated CLI sessions.
- Save the outgoing login's latest credentials. Journal authentication and audited local-preference changes; recover only recognized states. Never blindly restore an older refresh token.
- Preserve original Codex home, configuration, conversation databases, MCP and skills. Transfer only audited local project/conversation preferences. Target cloud caches, permissions and queued actions stay with their original owner.
- A missing/rejected official login produces a clear reauthorization result. Unexpected process/protocol/file failures remain distinct, sanitized failures.

## User experience

Reuse the existing Forui account page and interactions. The native snapshot supplies the platform's quit mode, which Flutter maps to an accurate confirmation message. Windows explains that activation forcibly closes Codex and may interrupt ongoing work. Cancellation changes no current login.

## Verification and delivery

1. Shared synthetic fixtures cover consistent identities, conflicting JWT identities, unknown fields, current/archived renderer owners and exclusion of account/cloud/queued state.
2. Native Windows checks use isolated stores and a controlled stdio child. Cover A → B → A, latest outgoing credentials, final child writes, correlation, timeout/EOF/cancellation, policy restrictions, unsafe files, conflicts and interrupted transactions. Tests never terminate a real desktop.
3. Flutter behavior checks cover Windows entry, native-only snapshots, explicit confirmation and platform-specific quit wording. Existing macOS checks remain passing.
4. Build a source- and lockfile-matched Windows candidate. On a real Windows 11 machine, authorize two identities, save/restart, switch A → B → A, verify the running desktop's actual identity, and inspect retained local projects/preferences. Keep credentials and private evidence outside Git.
5. Record actual platform coverage and any remaining macOS acceptance gap, complete independent review, merge through repository policy, verify remote main and clean task artifacts.
