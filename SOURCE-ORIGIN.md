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
