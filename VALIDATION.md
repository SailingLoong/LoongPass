# Validation receipt — 2026-11-03

Environment: isolated Linux cloud workspace, official Flutter 3.47.9 / Dart 3.13.7.

- `bash check.sh`: passed on final source.
- Formatting: 0 changed; analyzer: no issues.
- Flutter tests: 50/50 passed (27 filesystem, 8 platform-bridge, 14 Widget, 1 wrapper containing 29 pure-core checks).
- Standalone pure-core checks: 29/29 passed.
- Independent read-only review reran checks and found no remaining blockers for this limited slice.
- Filesystem tests used only generated temporary files and directories, deleted after each test. No actual client files, accounts or network endpoints were used.
- Actual Flutter page rendering at 1280×900 was generated and visually inspected; layout checks also cover widths 480 and 760.

A review found that lexical path normalization could hide a symlink followed by `..` and make the write target differ from the checked private directory. A failing regression reproduced this without concurrent mutation. The final adapter validates the original absolute path against its resolved path and rejects the alias; the regression passes.

Additional macOS work: the official runner is generated, the system file picker/temporary-scope bridge and Finder handoff are implemented, and the UI invokes the shared Dart backup. Bridge tests use actual synthetic filesystem operations but a mocked native channel. UI tests cover cancellation, busy state and sanitized failure. Six XCTest cases cover private directory creation/reuse, public directory, symlink, regular file, ACL, and special permission bits; these native tests have NOT run.

Plist parsing, selected-file read-only entitlement, app product/module/test-host consistency, and Swift API signatures were statically checked. The release entitlement adds no network client or user-selected write permission. A separate independent review reran all 50 Dart/Flutter tests and inspected the native bridge. Generated IDE metadata was removed; source, test fixtures, SDK and active caches were retained.

Important limits: account-list UI is still synthetic; no native credential replacement, live identity validation, check-in, Windows ACL adapter, macOS compilation, sandbox end-to-end test, signing, notarization or installer validation has been completed. The source package's beta version is an intended version, not evidence that a working real-account beta has been released.
