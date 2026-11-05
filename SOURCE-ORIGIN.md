# Current beta 18 source baseline

This checkout restores the reviewed source handoff for the delivered macOS 1.0.0 build 18. The Flutter project is at the repository root and the matching Rust source is in native/. The synthetic harness path follows that repository layout.

The handoff preserves the delivered business source. Its attribution additions and path-remapped universal native static library differ from the original build inputs. The original clean handoff archive has SHA-256 4a10a764f604e29efb74adf923d98b126cc4548aeba381f79bf3a663735441e5.

The beta 18 authorization-display issue remains open. Real account authorization, saving, restart recovery and LoongPass check-in have not passed acceptance. Older validation notes describe their recorded stages.

# Source provenance

- Upstream: SailingLoong/LoongPort.
- Immutable source commit: 9e1b7e574e1ca923d8ee5aab3cd7ede16a8872b6.
- Immutable source tree: a64268e64b391d856146ea0ddaef027e3d921715.
- Source: src-tauri/src/zcode_accounts/core.rs.
- License: MIT, retained in LICENSE. Copyright (c) 2025 Jason Young and (c) 2026 SailingLoong.
- lib/zcode_accounts.dart adapts the same-machine seven-field snapshot and switch decisions, ECMAScript identity normalization, and size/encoding checks.
- lib/zcode_auth_file.dart adapts the strict string-object parsing contract. Its limited backup-only filesystem adapter is new Dart code; it does not port the upstream native transaction, encryption, version admission, or claim runtime.
- lib/main.dart and its Widget tests are a new Flutter interface using synthetic fixtures. No account data, credentials, device IDs, or network receipts are included.
- This historical commit must not be described as the published beta.8 tag merely because its package version contains beta.8.

Validation baseline: 56 unchanged upstream Rust unit tests ran in an isolated narrow harness (37 core/native and 19 claim-state tests). The full historical backend harness was not successfully compiled; this baseline is not a full-client integration test.

Toolchain used for local verification: official Flutter 3.47.9, Dart 3.13.7. Official Linux SDK archive SHA-256: 25ed8c3c29d51a7353f2a944310b478af8214920639524b19c50a19e6c044c5a. The SDK, caches, executables, cloud logs, and temporary files are excluded from source delivery.

The macOS runner scaffolding was generated from the same official Flutter SDK, without downloading or installing another dependency. Its template BSD license is retained in THIRD_PARTY_NOTICES.md. MainFlutterWindow.swift adds the Cocoa file picker/private directory bridge; no old native claim runtime or device-identity logic is included.

lib/qoder_claim.dart ports the Qoder International campaign contract/request/clock semantics from qoder_daily/contract.rs, http.rs and clock.rs at the same immutable commit. Remote Git-blob hashes were checked for all three. It does not include a production authenticated transport, device source, database owner or scheduler. See QODER-PORT.md for exact hashes and integration boundaries.
