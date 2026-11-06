# Workspace UI Parity Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans, then one independent branch review.

**Goal:** Finish the approved desktop workspace and persistent app ordering.
**Architecture:** Stable platform identities and mounted pages; one UI-preference
owner; read-only presentation snapshots for auxiliary views. Domain owners unchanged.
**Tech Stack:** Flutter Material, shared_preferences async API, existing macOS build.
**Spec:** docs/superpowers/specs/2026-11-07-workspace-parity-design.md

## Global Constraints
- Four columns: account → balance → upcoming expiry → latest confirmed receipt.
- No credentials/business facts in UI preferences; no navigation-triggered I/O.
- Magpie page explicitly unavailable until a real integration exists.
- Preserve merged 19632db verification behavior and real-GUI ownership boundary.

## Review Focus
- Reordered navigation must retain the correct selected app and unfinished forms.
- Unknown/duplicate stored app IDs cannot hide new apps or duplicate regions.
- Rapid preference writes/failures must not claim persistence or overwrite later intent.
- Cross-platform projections must stay live and namespace identical account IDs.
- Empty/error snapshots cannot imply globally verified zero balances or full audit history.

### Task 1: Navigation and preferences
- [x] Add behavior tests for actual drag/reload, keyboard move and stable page state.
- [x] Add the UI-preference owner and native plugin, normalize stored app ordering.
- [x] Replace the oversized button, add region badges and auxiliary navigation.
- [x] Verify targeted tests and commit.
Files: lib/app_sidebar.dart, lib/managed_app.dart, lib/ui_preferences.dart,
lib/main.dart, pubspec.yaml/lock, test/app_sidebar_test.dart, test/ui_preferences_test.dart.

### Task 2: Design parity
- [x] Add tests for live read-only cross-platform views and persisted table preferences.
- [x] Add auxiliary pages and the presentation registry; restore Magpie access/status.
- [x] Align platform header/actions/help and table filters, timestamps, empty states.
- [x] Run targeted and full Flutter checks, update the parity evidence and commit.
Files: shared workspace/presentation components, compact_accounts_table.dart,
five platform panels, their existing tests, tool/render_compact_accounts_test.dart.

### Task 3: Acceptance and delivery
- [ ] Run tool/check.py; render real widgets at wide/narrow light/dark sizes.
- [ ] Request one fresh read-only review of this task's changes; fix material findings.
- [ ] Build one beta28 Universal candidate under shared locks, verify and archive.
- [ ] Update draft PR/evidence, preserve source branch; clean task intermediates.

Execution authorization: Allen explicitly requested development in this chat;
routine implementation choices are settled inline without another design gate.
