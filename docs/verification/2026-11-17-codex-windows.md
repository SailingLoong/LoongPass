# Codex Windows account activation

## Implementation

The Windows native owner supplies the existing Flutter account page with saved official identities and read-only snapshots. The official Store package is discovered at runtime. The desktop application is selected by its adjacent official CLI capability; extension-host and command-runner registrations are not desktop candidates.

Official configuration, browser authorization and renewal use an owned stdio app-server child. Credentials remain native. The child is stopped and reaped before reading its final grant. Cancellation, EOF, timeout and normal shutdown clean up owned work and private temporary homes. The macOS authorization/renewal paths now also read the final grant after child shutdown.

Activation asks for closure confirmation, preserves the outgoing account's latest grant, refuses unrelated command-line writers, observes the selected desktop tree's exit, revalidates the package and effective policy, and applies authentication with audited local preferences in a journaled transaction. Successful activation opens Codex, including when it was previously stopped. A failed action restores a desktop that it interrupted. Windows discloses forced termination; macOS requests application exit and preserves Codex's own force-quit/cancellation dialog.

Saved credentials and newly staged files use private user/SYSTEM permissions. Existing official files can retain Codex's read-only sandbox access; foreign write access, reparse points, hard-linked credentials, unexpected file changes and unrecognized recovery states are refused. Configuration, conversation databases, MCP and skills are outside the write API. Cloud caches, capabilities and queued actions are not transferred to the target identity.

The C++ code is necessary Windows SDK integration within the existing Flutter application. The UI continues to use Forui and the existing font/theme contract. Shared synthetic fixtures check parity with the macOS identity and preference projection.

## Verified before real acceptance

- Windows MSVC `/W4 /WX`: shared identity/preference fixtures; A → B → A file transactions; latest outgoing grants; restart persistence; CAS refusal; recovery; hardlinks/stage collision; policy restrictions; multi-application package discovery; existing-reader/foreign-writer ACL boundaries.
- Controlled stdio child: request correlation, early login notification, malformed/oversized frames, EOF, timeout, cancellation, process reaping and credentials written during final shutdown.
- Injected activation boundary: success opens a stopped desktop; incompatible post-quit policy preserves authentication; failed and partially completed termination restore the previous desktop.
- Windows Flutter 3.50.0 / Dart 3.14.0: static analysis and 28 Codex controller/widget checks, including Windows availability, closure wording, cancellation, native-only snapshots and narrow layouts. Dependency resolution enforced the unchanged lockfile.
- macOS native checks: account, local settings, paired transaction, stdio runtime, process classification, shared fixture parity and updated automatic-open boundary.
- Read-only Windows official-client probe: Store discovery, effective file-store policy and parsing the current credential shape passed. This did not replace the current login.

## Acceptance boundary

Real Windows desktop A → B → A, saved-account restart persistence, package installation and visual/interaction acceptance are pending in this record. File transactions, mock UI checks and the read-only official probe do not establish a successful running-desktop switch. The original macOS two-account desktop round trip also remains unverified; the local Mac hosts active Codex work.

Private logs and account evidence remain outside Git under the task's artifact directory. The user authorized transferring two existing Mac grants to the Windows acceptance machine over SSH; grant portability and actual online identities must be established by the official client.
