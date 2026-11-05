# Current validation boundary — 2026-11-04

This is the isolated minimal UI wiring candidate, not a compiled application or a real-account acceptance result. Earlier test counts belong to prior source versions and do not establish behavior of these bytes.

## Implemented in source

- Existing four-App sidebar retained, with one Qoder CN coordinator and one MiniMax account service per panel lifetime.
- Qoder CN: reviewed real HTTPS adapter + own-Keychain bridge copied unchanged; explicit persistent-authorization dialog, fixed official-browser URL, manual authorization-result check/cancel, saved-UID enumeration and explicit benefit request.
- MiniMax: reviewed real HTTPS adapter + own-Keychain/nonsecret metadata bridge copied unchanged; region-specific selected file verification, server UID preview, separate persistent credential approval, account list, explicit claim, opt-in in-process automatic checks.
- Runner registers both native adapters and includes their Swift sources plus one shared LoongPassKeychainLock in Compile Sources. All owned Security operations use the shared synchronous lock. Qoder uses classic login Keychain with synchronizable=false and no unsupported ThisDeviceOnly attribute.
- Debug/Profile and Release entitlement files now add `com.apple.security.network.client`. Static plist comparison confirms this is their only capability delta. Existing user-selected read-only scope remains; no selected-file write capability was added.
- No account or network access occurs just by mounting/navigating the new panels. MiniMax saved automatic settings resume only after the explicit load action or opt-in, and stop on service disposal. The automatic-finished callback refreshes account records; busy UI defers that refresh, and a UI epoch rejects stale reads.

## Release acceptance gate

`nativeAccountAdaptersValidated` is false. Both new panels disable real-account controls until Mac compilation, isolated native Keychain tests and independent review establish native acceptance. Injected synthetic owners remain usable by test harnesses. A macOS platform check alone is not sufficient.

## Actually verified here

Python static source/hash/plist checks: local Dart imports exist; copied modules match frozen reviewed bytes; two panel instances appear exactly once; native build entries exist; entitlement delta is limited to outbound client networking. Evidence: `../evidence/static-result.json` and `../SHA256-MANIFEST.json`.

Original integration candidate remains untouched. Standalone component evidence (Qoder CN 26 synthetic checks; MiniMax 26 action checks plus HTTP checks) belongs to their independently reviewed modules. It is NOT a current combined Flutter/native test pass.

## Not verified

No Dart analyzer/formatter, Flutter widget/test suite, native Swift/Xcode build, actual rendered UI, macOS sandbox/picker release, Keychain access/durability, signing, installer, real login, real check-in, live endpoint compatibility or credited balance was executed for this composition. Previously denied tests were not retried. New panel widget tests are unexecuted drafts.

All real desktop credential switching remains unimplemented. Qoder CN automatic scheduling/refresh is unimplemented. WorkBuddy lacks an integrated secure owner and complete-balance path, so no runnable WorkBuddy control is exposed. MiniMax automatic execution only exists while this application runs and its account service has been explicitly loaded; unknown requests remain non-replayable and have no reconciliation UI.

Required next gates: independent source review, permitted Flutter checks, Mac compile and dedicated synthetic native/Keychain validation, then separately authorized real-account acceptance. Until these gates are satisfied this is not a usable beta or evidence that any account signed in or received a reward.
