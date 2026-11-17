# Explicit Magpie Model Publication Implementation Plan

> **For agentic workers:** Execute inline with superpowers:executing-plans; use test-driven-development and one final independent review.

**Goal:** Magpie offers Auto by default and offers individual models only after the user explicitly selects them.

**Architecture:** Keep Auto participation separate from publication. Build one flat native Auto group from account-scoped model bindings in the owner's existing model/expiry order, plus native groups for explicitly published models. Keep the native provider unlisted; Magpie still owns protocol conversion, session affinity, retries and failover.

**Tech Stack:** Existing Flutter / Forui UI, Dart data owners, and the pinned Magpie native plugin contract.

**Spec:** The behavior and constraints below implement Allen's request in this chat.

## Behavior and constraints

- New, upgraded and newly discovered concrete models start unpublished. Previous Auto settings, account grants and ordering remain intact.
- Publishing/unpublishing persists and synchronizes through the existing data-layer connection owner, independently of page lifetime.
- A model may be used by Auto without being individually published, and may be published without participating in Auto.
- The sidebar shows Auto and published models. Search/show-all lets users opt models in; switches clearly distinguish publication from Auto participation.
- Native dependencies remain internal to the provider. The public model catalog contains only Auto and explicit choices, including image models.
- Use account-scoped model IDs and native account allowlists so a flat ordered group preserves exact model/account expiry preference and failover.
- Retain the existing Auto request alias for configured clients; do not add supplier translation or client-specific prompt handling.
- Use the existing task worktree, protect credentials, review before merging, verify remote main and update the workspace gitlink.

## Review focus

- Old configurations with every model enabled must not become explicit publication choices.
- Publication must not empty Auto or reactivate disabled grants/accounts.
- Public list changes must include image models and remove old owned groups.
- Reordering and exact per-model account expiry must remain correct after flattening.
- Installed WorkBuddy must still complete a real Auto request after the catalog shrinks.

## Task 1: Publication state and native routing

**Files:** `plugin_model_catalog.dart`, `plugin_model_service.dart`, `magpie_connection.dart`, `model_connection.dart`, the bridge modules, and their focused tests.

**Interfaces:** Persist explicit publication in routing settings; project eligible bindings into native groups once; both synchronization and its journal consume that projection.

- [x] Add and run failing routing/catalog tests for default-only Auto, opt-in/out, migration and account order.
- [x] Implement the independent preference and the flat native routing projection; remove redundant public aliases and quota-strategy snapshots.
- [x] Verify focused Dart/native bridge tests, including manually published models excluded from Auto and image bindings.

## Task 2: Model selection UI

**Files:** `plugin_model_page.dart`, `plugin_model_list.dart`, `main.dart`, and widget/workspace tests.

**Interfaces:** The primary model switch edits publication; model details separately edit Auto participation. The sidebar consumes explicit publication.

- [x] Add and run failing widget tests for the empty default list, search/opt-in/out and independent Auto state.
- [x] Implement using existing Forui components and responsive layouts; clarify the existing Auto bulk-filter action.
- [x] Verify normal and narrow/200% layouts and sidebar selection behavior.

## Task 3: Delivery and real acceptance

- [x] Run the complete repository checks and an independent source review.
- [x] Query an isolated installed Magpie profile to prove the actual public list and native failover behavior.
- [ ] Build once, install, inspect the running UI, and test WorkBuddy Auto plus publication/unpublication/restart.
- [ ] Finish WorkBuddy UI acceptance after Mac unlock, then merge green CI to remote main, update the workspace pointer, and clean eligible task intermediates. Exact evidence and coverage boundaries are recorded in the verification document and private local artifacts.
