# Codex Windows implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task. Implementation remains in the current task worktree.

**Goal:** Enable official Codex accounts on Windows and verify an actual desktop account round trip.

**Architecture:** The existing Flutter adapter consumes native snapshots. A Windows coordinator uses the existing private file owner, Codex-specific credential/settings transactions, and an official-client runtime. OS-specific operations remain native; shared fixtures define the cross-platform identity and local-preference contract.

**Tech stack:** Flutter/Dart and the existing Forui UI; C++17 and Windows SDK bridges; installed official Codex CLI.

**Spec:** `docs/superpowers/specs/2026-11-16-codex-windows-design.md`.

## Global constraints

- Credentials never cross the Flutter channel or enter Git/logs.
- Only the official file credential store is supported; do not rewrite configuration or conversation databases.
- Observations and refreshes belong to the native account owner; snapshot reads have no upstream side effects.
- Reuse the existing private storage owner and preserve the macOS account schema.
- Runtime discovery uses package/application metadata and executable capabilities, not versioned installation paths.
- A desktop switch requires actual desktop identity verification; mocks/builds/file writes do not establish acceptance.
- Use the repository's pinned Flutter SDK and dependency lock without mirror-driven package upgrades.

## Review focus

- A refresh or final child shutdown write must not leave the saved grant stale.
- A desktop update, other CLI writer or concurrent auth edit must prevent committing the wrong identity.
- Renderer changes must preserve local preferences without importing another account's cloud/queued state.
- Cancellation, EOF, timeout and application shutdown must reap owned processes and remove temporary authorization data.
- Unsupported credential stores or enforced workspace policies must leave the current authentication intact.

### Task 1: Credential, preference and file transaction contract

**Files:** Shared fixtures under `test/fixtures/`; Windows `codex_account_state.*` and `codex_account_store.*`; narrow private-file accessors in `native_storage.*`; `tool/windows_codex_checks.cpp`; native check target in CMake; existing Swift checks as needed for fixture parity.

**Interfaces:** `CodexCredential` projects native auth bytes; `CodexLocalSettings` transfers audited local preferences; `CodexAccountStore` captures/removes/observes saved accounts and activates a selected identity in a guarded home. The existing native file owner remains the persistence primitive.

- [ ] Write shared synthetic conformance fixtures and failing Windows transaction checks; confirm the absent implementation fails.
- [ ] Implement native projections and account persistence with reused private-file ownership.
- [ ] Implement guarded authentication/settings activation and recovery; verify latest outgoing credentials, unsafe paths, CAS refusal and interrupted transactions.
- [ ] Run native conformance/transaction checks and existing storage checks, then commit this independently testable change.

### Task 2: Official Windows client runtime and account coordinator

**Files:** Windows `codex_runtime.*` and `codex_accounts.*`; standalone controlled-child checks in `tool/windows_codex_checks.cpp`.

**Interfaces:** `CodexDesktopClient` discovers the installed official package and handles explicit exit/reopen. `CodexAppServer` owns a bounded, cancellable stdio child. `CodexAccounts` owns worker lifetime, read-only snapshots and method-channel operations.

- [ ] Add failing controlled-child checks for request correlation, terminal states and final credential writes.
- [ ] Implement runtime package/application discovery, effective policy loading and official authorization/renewal.
- [ ] Implement Windows process-tree exit/reopen with unrelated CLI protection and observed completion.
- [ ] Implement the serialized native owner, main-thread channel completion, data-owned observation and cancellation/shutdown cleanup.
- [ ] Run the complete Windows Codex native checks and commit.

### Task 3: Flutter entry and native integration

**Files:** `lib/codex_accounts.dart`, `lib/codex_accounts_panel.dart`, corresponding Flutter tests, `windows/runner/flutter_window.*`, native CMake, macOS snapshot metadata and repository check workflows.

- [ ] Add and run a failing Flutter check showing the Windows entry is currently unavailable.
- [ ] Connect the Windows owner, enable Windows support and display native quit-mode wording in the existing confirmation.
- [ ] Add Windows native checks to the existing CI/build path; preserve the current macOS behavior and check coverage.
- [ ] Run Flutter analysis/tests and relevant native checks; compile both affected platform integration paths, then commit.

### Task 4: Real acceptance and integration

**Files:** Public verification/source-origin notes; private evidence outside Git.

- [ ] Reuse the Windows toolchain/build caches and machine build lock, build the exact candidate and preserve its source/lock/toolchain fingerprints.
- [ ] Install on the Windows acceptance machine; import/authorize two official identities and verify restart persistence.
- [ ] Execute real A → B → A, inspect the running desktop identity and local project/preference continuity, and record actual results without credentials.
- [ ] Review the full branch independently, resolve material findings, complete repository checks and merge through required policy to remote main.
- [ ] Verify remote main contains the task commits, update the workspace pointer if required, and clean this task's worktree, branch and idle build products safely.
