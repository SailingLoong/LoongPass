# Codex official account adapter

## Implemented behavior

The macOS adapter saves multiple official ChatGPT/Codex logins in the existing private account store. User plus ChatGPT workspace identifies an account; email alone does not. Credentials remain native and are never sent through the Flutter channel. The account file is plaintext with private directory/file permissions, consistent with the application's current storage policy.

New authorization and renewal use the installed, signature-checked official executable selected from its package manifest. Temporary authorization homes do not replace the user's normal Codex home and are removed on completion, cancellation or error. Normal LoongPass termination waits for owned authorization jobs to clean up.

Explicit activation normally quits the official desktop, refuses other active Codex command-line writers, and saves the outgoing account's latest credentials. Current Codex account-isolates renderer state: the adapter seeds the target's local project/conversation preferences before replacing `auth.json` in one journaled transaction. Shared settings, the source snapshot, other accounts and target cloud/auth/capability/queued-action data stay with their owners. Paired failure restores only recognized exact settings preimages; authentication is never blindly restored from an older refresh token. The previous desktop is reopened when it had been running.

The adapter does not rewrite `config.toml`, conversation databases, MCP configuration or skills. Local project order, pins, sidebar choices, draft/model preferences and local conversation associations are carried through the audited renderer snapshot contract. A desktop that stays closed can retain renderer owner A after auth advances to B; the settings source follows that known saved renderer owner, while outgoing credentials still follow the live authentication file. Unknown owners or unsupported renderer schemas stop before authentication changes. Cloud conversations, subscriptions, connected services and workspace permissions remain controlled by the selected official account. Applied/reopened outcomes do not assert a verified online client switch.

## Automated and local verification

- 263 Flutter tests and static analysis passed, including controller/widget actions, confirmation cancellation, late responses, narrow layout, unsupported platforms and preserved navigation preferences.
- On the local Mac, synthetic account/detail views were rendered and visually checked at 1280 and 480 logical pixels. Both render checks passed without layout exceptions; no actual account data or installed-client write was involved.
- Repository platform checks and standalone native checks cover A → B → A; exact unchanged config and conversation fixtures; legacy preference byte preservation; current/archived renderer owners; repeated switches with the desktop closed; target-cache isolation; fresh credentials; unsafe paths/writers; and paired refusal/crash recovery. Settings replacement retains existing file permissions.
- The actual installed renderer owner-transition method was executed against an isolated native projected fixture. Startup restored the original local projects and composer preference while retaining the target's cloud cache. This is a protocol characterization, not a running-desktop account acceptance. The inspected renderer method SHA-256 is `b4671678c6832b32107b1668162a86e67aa832cce3a75c6beb99e600390f2602`.
- The stdio client checks correlate request ids and login completion, enforce timeouts, reject EOF, and honor effective credential-store and workspace restrictions. Process checks cover official desktop children, a separate CLI and the official Node wrapper.
- Review regression checks reproduce a concurrent-close race before its fix; all close callers now wait for the same child termination/reap. Activation re-reads effective policy after normal quit and package revalidation. Real-file tests reject a newly incompatible store/workspace without replacing authentication and restore the previously running desktop through an injected OS boundary. Operation completion reconciles live authentication after events suppressed during a job.
- Read-only installed-client compatibility passed: signed package/manifest discovery, isolated official config/account RPC, and parsing the actual current credential shape without saving it. No official login, logout, account switch or desktop restart occurred in that check.

## Remaining acceptance and release scope

This change has not been published as an application release. The local Universal candidate passed compilation, deep strict signature verification and arm64/x86_64 architecture checks for the app and Flutter frameworks. Release binaries do not carry debugger-attachment entitlement. The candidate still uses the existing version label and is archived separately from the public release.

Real two-account authorization, restart persistence and A → B → A verification in the actual Codex desktop remain unverified. Automated tests deliberately use isolated homes and cannot stand in for that acceptance. Apple Silicon and Intel binary coverage do not establish Intel device coverage.

Only the existing `file` credential store is supported. `keyring`, `auto`, `ephemeral` and unknown stores remain unavailable without rewriting the user's settings or accessing Keychain. Enforced login/workspace restrictions are checked through Codex's own configuration loader. Windows and other platforms display an unavailable state; they do not offer a simulated switch.
